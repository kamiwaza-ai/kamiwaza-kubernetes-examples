#!/usr/bin/env python3
"""Make Kaizen *spawned sandbox* pods trust the corporate CA — config-only, no new image.

The Kaizen sandbox-controller builds every agent sandbox pod programmatically in
``kaizen/sandbox_controller/backends/kubernetes.py`` (methods ``_build_pod`` and
``_build_resume_pod``). Customer Helm values and the KamiwazaExtension CR cannot add a
volume to those *spawned* pods — only the controller code decides their pod spec. So the
config-only way to get the ``kamiwaza-trust-bundle`` ConfigMap mounted into every sandbox
is to overlay a tiny patch onto that one controller file and let the controller mount the
bundle itself.

This script does that WITHOUT building or shipping a new image:

  1. EXTRACT the *live* ``kubernetes.py`` from the running sandbox-controller pod (so the
     overlay is always byte-matched to the deployed controller version — no drift).
  2. INJECT the ``kamiwaza-trust-bundle`` volume + volumeMount into ``_build_pod`` and
     ``_build_resume_pod`` (idempotent; fails closed if the expected anchors are absent).
  3. VALIDATE the result with ``py_compile``.
  4. CREATE a ConfigMap (default ``kaizen-controller-trust-patch``) holding the patched file.
  5. PATCH the live KamiwazaExtension CR so the ``sandbox-controller`` service subPath-mounts
     that file over the in-image path. The operator rolls the controller once; from then on
     every ``_build_pod``/``_build_resume_pod`` mounts the bundle into the sandbox at
     ``/etc/ssl/certs/ca-certificates.crt`` (where the agent entrypoint already points
     ``SSL_CERT_FILE``/``REQUESTS_CA_BUNDLE``).

Prereqs:
  - The parent tls-trust packet is green, and the ``kamiwaza-trust-bundle`` ConfigMap exists
    in ``kamiwaza-sandboxes`` (run ``build-trust-bundle-configmap.sh --include-sandboxes``).
  - A Kaizen extension is deployed (its sandbox-controller pod is running).

Durability / scope: the overlay lives in the controller, so it applies to every future
sandbox spawn (new conversation, resume, stop→start) for THIS extension. It does NOT
retro-fit already-running sandboxes (resume them), and each Kaizen extension has its own
controller (re-run per extension). See README.md.

Requirements: python3, kubectl. NO docker, NO image rebuild, NO trust-manager.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List

BUNDLE_NAME = "kamiwaza-trust-bundle"
BUNDLE_KEY = "ca-certificates.crt"
BUNDLE_PATH = "/etc/ssl/certs/ca-certificates.crt"

# Marker so re-runs are idempotent and so verify tooling can detect the overlay.
SENTINEL = "kamiwaza-trust-bundle (tls-trust)"

DEFAULT_NS = "kamiwaza-extensions"
DEFAULT_CONTROLLER_SERVICE = "sandbox-controller"
DEFAULT_CONFIGMAP = "kaizen-controller-trust-patch"
CODE_VOLUME_NAME = "trust-controller-code"
CODE_FILENAME = "kubernetes.py"

# Where the controller module lives in the image. Auto-detected at runtime; this is the
# fallback for the 1.5.x agent/controller images (python3.12).
DEFAULT_SITE_PACKAGES_PATH = (
    "/usr/local/lib/python3.12/site-packages/kaizen/sandbox_controller/backends/kubernetes.py"
)
CONTROLLER_MODULE = "kaizen.sandbox_controller.backends.kubernetes"


# ---------------------------------------------------------------------------
# The injection transform (pure function — unit-testable via --print-only --from-file)
# ---------------------------------------------------------------------------
def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


# Relative-indented snippets; re-indented to each anchor's list-item column at apply time.
_MOUNT_SNIPPET = [
    f"client.V1VolumeMount(  # {SENTINEL}",
    f'    name="{BUNDLE_NAME}",',
    f'    mount_path="{BUNDLE_PATH}",',
    f'    sub_path="{BUNDLE_KEY}",',
    "    read_only=True,",
    "),",
]
_VOLUME_SNIPPET = [
    f"client.V1Volume(  # {SENTINEL}",
    f'    name="{BUNDLE_NAME}",',
    "    config_map=client.V1ConfigMapVolumeSource(",
    f'        name="{BUNDLE_NAME}",',
    f'        items=[client.V1KeyToPath(key="{BUNDLE_KEY}", path="{BUNDLE_KEY}")],',
    "        optional=True,",
    "    ),",
    "),",
]


def inject_trust_mount(src: str) -> str:
    """Insert the trust-bundle volume + volumeMount into every pod builder.

    Keys off the structural anchors ``volume_mounts=[`` and ``volumes=[`` (which appear
    once per pod-building method) and inserts our entry as the first list item. Idempotent.
    Raises if the anchors are missing — we refuse to ship a no-op/garbled overlay.
    """
    if SENTINEL in src:
        return src  # already patched

    out: List[str] = []
    mounts_patched = 0
    volumes_patched = 0
    for line in src.splitlines():
        out.append(line)
        stripped = line.strip()
        if stripped == "volume_mounts=[":
            pad = " " * (_indent_of(line) + 4)
            out.extend(pad + s for s in _MOUNT_SNIPPET)
            mounts_patched += 1
        elif stripped == "volumes=[":
            pad = " " * (_indent_of(line) + 4)
            out.extend(pad + s for s in _VOLUME_SNIPPET)
            volumes_patched += 1

    if mounts_patched == 0 or volumes_patched == 0:
        raise RuntimeError(
            "could not find the expected pod-builder anchors "
            f"(volume_mounts=[ x{mounts_patched}, volumes=[ x{volumes_patched}). "
            "The controller source differs from the expected shape — aborting rather "
            "than shipping a broken overlay. Inspect the extracted file with --print-only."
        )
    if mounts_patched != volumes_patched:
        raise RuntimeError(
            f"unbalanced anchors (mounts={mounts_patched}, volumes={volumes_patched}); "
            "refusing to apply a partial overlay."
        )

    result = "\n".join(out)
    if src.endswith("\n") and not result.endswith("\n"):
        result += "\n"
    return result


# ---------------------------------------------------------------------------
# kubectl / process helpers
# ---------------------------------------------------------------------------
def _run(*args: str, input_text: str | None = None, check: bool = True) -> str:
    proc = subprocess.run(
        list(args), input=input_text, text=True, capture_output=True, check=False
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({' '.join(args)}):\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    return proc.stdout


def _resolve_controller_pod(namespace: str, ext_name: str, service: str) -> str:
    selector = (
        f"extensions.kamiwaza.io/deployment-id={ext_name},"
        f"extensions.kamiwaza.io/service={service}"
    )
    out = _run(
        "kubectl", "-n", namespace, "get", "pods", "-l", selector, "-o", "name", check=False
    ).strip()
    pod = out.splitlines()[0] if out else ""
    if not pod:
        raise RuntimeError(
            f"no running '{service}' pod found for extension '{ext_name}' in ns '{namespace}'. "
            "Deploy the Kaizen extension first (the controller runs before any conversation), "
            "or pass --from-file with a kubernetes.py extracted offline."
        )
    return pod  # e.g. "pod/kaizen-abc-sandbox-controller-xxxx"


def _detect_module_path(namespace: str, pod: str) -> str:
    out = _run(
        "kubectl", "-n", namespace, "exec", pod, "--",
        "python", "-c",
        f"import {CONTROLLER_MODULE} as m,sys; sys.stdout.write(m.__file__)",
        check=False,
    ).strip()
    return out or DEFAULT_SITE_PACKAGES_PATH


def _extract_live_file(namespace: str, pod: str, path: str) -> str:
    return _run("kubectl", "-n", namespace, "exec", pod, "--", "cat", path)


def _py_compile_or_die(text: str) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=True) as fh:
        fh.write(text)
        fh.flush()
        proc = subprocess.run(
            [sys.executable, "-m", "py_compile", fh.name],
            text=True, capture_output=True, check=False,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"patched controller file failed py_compile:\n{proc.stderr}")


def _configmap_yaml(namespace: str, name: str, patched: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / CODE_FILENAME
        f.write_text(patched)
        return _run(
            "kubectl", "create", "configmap", name,
            "--from-file", f"{CODE_FILENAME}={f}",
            "-n", namespace, "--dry-run=client", "-o", "yaml",
        )


# ---------------------------------------------------------------------------
# KamiwazaExtension CR patch (name-keyed upsert on the sandbox-controller service)
# ---------------------------------------------------------------------------
def _load_extension(name: str, namespace: str) -> Dict[str, Any]:
    return json.loads(
        _run("kubectl", "-n", namespace, "get", "kamiwazaextension", name, "-o", "json")
    )


def _upsert_named(items: List[Dict[str, Any]], desired: Dict[str, Any]) -> None:
    for i, entry in enumerate(items):
        if entry.get("name") == desired["name"]:
            items[i] = desired
            return
    items.append(desired)


def _patch_controller_service(
    obj: Dict[str, Any], service_name: str, configmap_name: str, mount_path: str
) -> Dict[str, Any]:
    spec = obj.get("spec") or {}
    services = spec.get("services") or []
    if not isinstance(services, list) or not services:
        raise RuntimeError("spec.services missing or invalid on the live KamiwazaExtension")

    target = next((s for s in services if s.get("name") == service_name), None)
    if target is None:
        raise RuntimeError(
            f"service '{service_name}' not found on the extension "
            f"(have: {', '.join(s.get('name', '?') for s in services)})"
        )

    _upsert_named(
        target.setdefault("volumes", []),
        {
            "name": CODE_VOLUME_NAME,
            "configMap": {
                "name": configmap_name,
                "items": [{"key": CODE_FILENAME, "path": CODE_FILENAME}],
            },
        },
    )
    _upsert_named(
        target.setdefault("volumeMounts", []),
        {
            "name": CODE_VOLUME_NAME,
            "mountPath": mount_path,
            "subPath": CODE_FILENAME,
            "readOnly": True,
        },
    )

    metadata = obj.get("metadata") or {}
    cleaned: Dict[str, Any] = {
        "apiVersion": obj["apiVersion"],
        "kind": obj["kind"],
        "metadata": {"name": metadata["name"], "namespace": metadata.get("namespace", namespace_of(obj))},
        "spec": spec,
    }
    if metadata.get("labels"):
        cleaned["metadata"]["labels"] = metadata["labels"]
    if metadata.get("annotations"):
        cleaned["metadata"]["annotations"] = metadata["annotations"]
    return cleaned


def namespace_of(obj: Dict[str, Any]) -> str:
    return (obj.get("metadata") or {}).get("namespace", DEFAULT_NS)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("name", help="KamiwazaExtension name, e.g. kaizen-a1b2c3d4")
    p.add_argument("--namespace", default=DEFAULT_NS, help=f"Extension namespace (default: {DEFAULT_NS})")
    p.add_argument("--controller-service", default=DEFAULT_CONTROLLER_SERVICE,
                   help=f"Controller service name (default: {DEFAULT_CONTROLLER_SERVICE})")
    p.add_argument("--configmap-name", default=DEFAULT_CONFIGMAP,
                   help=f"ConfigMap to hold the patched file (default: {DEFAULT_CONFIGMAP})")
    p.add_argument("--from-file", default="",
                   help="Patch THIS kubernetes.py instead of extracting from the live controller "
                        "(e.g. one extracted from the image offline).")
    p.add_argument("--site-packages-path", default="",
                   help="Override the in-image module path to mount over "
                        f"(default: auto-detect, fallback {DEFAULT_SITE_PACKAGES_PATH}).")
    p.add_argument("--print-only", action="store_true",
                   help="Print the patched file, the ConfigMap, and the CR patch; apply nothing.")
    p.add_argument("--skip-cr-patch", action="store_true",
                   help="Build/apply the ConfigMap only; do not touch the KamiwazaExtension CR "
                        "(e.g. you patch the CR elsewhere).")
    args = p.parse_args()

    # 1. Get the controller source (live extraction by default).
    if args.from_file:
        source = Path(args.from_file).read_text()
        mount_path = args.site_packages_path or DEFAULT_SITE_PACKAGES_PATH
    else:
        pod = _resolve_controller_pod(args.namespace, args.name, args.controller_service)
        mount_path = args.site_packages_path or _detect_module_path(args.namespace, pod)
        source = _extract_live_file(args.namespace, pod, mount_path)

    # 2. Inject + 3. validate.
    patched = inject_trust_mount(source)
    if patched == source and SENTINEL in source:
        sys.stderr.write("note: controller source already carries the trust overlay (idempotent).\n")
    _py_compile_or_die(patched)

    # 4. Render the ConfigMap.
    cm_yaml = _configmap_yaml(args.namespace, args.configmap_name, patched)

    if args.print_only:
        sys.stdout.write(f"# ===== patched {CODE_FILENAME} (mount path: {mount_path}) =====\n")
        sys.stdout.write(patched)
        sys.stdout.write("\n# ===== ConfigMap =====\n")
        sys.stdout.write(cm_yaml)
        if not args.skip_cr_patch:
            obj = _load_extension(args.name, args.namespace)
            cleaned = _patch_controller_service(obj, args.controller_service, args.configmap_name, mount_path)
            sys.stdout.write("\n# ===== KamiwazaExtension CR patch =====\n")
            sys.stdout.write(json.dumps(cleaned, indent=2) + "\n")
        return 0

    # 4b. Apply the ConfigMap.
    _run("kubectl", "apply", "-f", "-", input_text=cm_yaml)
    print(f"applied ConfigMap {args.namespace}/{args.configmap_name} ({CODE_FILENAME})")

    # 5. Patch the CR so the controller mounts the overlay.
    if args.skip_cr_patch:
        print("skipped CR patch (--skip-cr-patch). Mount the ConfigMap on the sandbox-controller "
              f"service at {mount_path} (subPath {CODE_FILENAME}) yourself.")
        return 0

    obj = _load_extension(args.name, args.namespace)
    cleaned = _patch_controller_service(obj, args.controller_service, args.configmap_name, mount_path)
    _run("kubectl", "apply", "-f", "-", input_text=json.dumps(cleaned) + "\n")
    print(f"patched {args.namespace}/{args.name}: {args.controller_service} now mounts "
          f"{args.configmap_name} over {mount_path}")
    print("next:")
    print("  - the operator rolls the controller; wait a few seconds and re-check (reconcile is async)")
    print("  - ensure kamiwaza-trust-bundle exists in kamiwaza-sandboxes "
          "(build-trust-bundle-configmap.sh --include-sandboxes)")
    print("  - open/resume a Kaizen conversation to spawn a FRESH sandbox, then:")
    print(f"      security/tls-trust/extensions/verify-kaizen.sh {args.name} https://<corp-ca-endpoint>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
