#!/usr/bin/env python3
"""Patch a live Kaizen KamiwazaExtension CR for the 0.13.0 TLS trust hotfix.

This script updates the declared Kaizen services in-place:
  - backend
  - sandbox-controller

It does NOT claim to solve spawned sandbox pods; use verify-kaizen.sh after
opening a Kaizen conversation to prove whether the sandbox path inherits trust.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any, Dict, List


BUNDLE_NAME = "kamiwaza-trust-bundle"
BUNDLE_PATH = "/etc/ssl/certs/ca-certificates.crt"
BUNDLE_KEY = "ca-certificates.crt"
EXT_NS = "kamiwaza-extensions"

CA_ENV = {
    "SSL_CERT_FILE": BUNDLE_PATH,
    "REQUESTS_CA_BUNDLE": BUNDLE_PATH,
    "AWS_CA_BUNDLE": BUNDLE_PATH,
}

# Set as DIRECT service env on the backend. A container's direct `env` overrides
# any same-key value coming from `envFrom` (the operator-generated
# `<deployment-id>-config` ConfigMap). When the platform was generated in insecure
# TLS mode it leaves a stale direct `KAMIWAZA_TLS_REJECT_UNAUTHORIZED=0` on the
# backend that shadows the ConfigMap's value, so we must override it here as a
# direct env too — setting only spec.kamiwaza.tlsRejectUnauthorized (ConfigMap)
# is not enough.
BACKEND_VERIFY_ENV = {
    "AGENT_DISABLE_SSL_VERIFY": "false",
    "KAMIWAZA_VERIFY_SSL": "true",
    "KAMIWAZA_TLS_REJECT_UNAUTHORIZED": "1",
}


def _run(*args: str, input_text: str | None = None) -> str:
    proc = subprocess.run(
        list(args),
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({' '.join(args)}):\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    return proc.stdout


def _load_extension(name: str, namespace: str) -> Dict[str, Any]:
    raw = _run(
        "kubectl",
        "-n",
        namespace,
        "get",
        "kamiwazaextension",
        name,
        "-o",
        "json",
    )
    return json.loads(raw)


def _upsert_env(env_list: List[Dict[str, Any]], name: str, value: str) -> None:
    for entry in env_list:
        if entry.get("name") == name:
            entry.clear()
            entry.update({"name": name, "value": value})
            return
    env_list.append({"name": name, "value": value})


def _upsert_volume(service: Dict[str, Any]) -> None:
    volumes = service.setdefault("volumes", [])
    desired = {
        "name": "trust-bundle",
        "configMap": {
            "name": BUNDLE_NAME,
            "optional": True,
            "items": [{"key": BUNDLE_KEY, "path": BUNDLE_KEY}],
        },
    }
    for volume in volumes:
        if volume.get("name") == "trust-bundle":
            volume.clear()
            volume.update(desired)
            return
    volumes.append(desired)


def _upsert_volume_mount(service: Dict[str, Any]) -> None:
    mounts = service.setdefault("volumeMounts", [])
    desired = {
        "name": "trust-bundle",
        "mountPath": BUNDLE_PATH,
        "subPath": BUNDLE_KEY,
        "readOnly": True,
    }
    for mount in mounts:
        if mount.get("name") == "trust-bundle":
            mount.clear()
            mount.update(desired)
            return
    mounts.append(desired)


def _patch_service(service: Dict[str, Any], extra_env: Dict[str, str]) -> None:
    env_list = service.setdefault("env", [])
    for key, value in CA_ENV.items():
        _upsert_env(env_list, key, value)
    for key, value in extra_env.items():
        _upsert_env(env_list, key, value)
    _upsert_volume(service)
    _upsert_volume_mount(service)


def _derive_backend_base_url(
    obj: Dict[str, Any],
    explicit_base_url: str,
) -> str:
    if explicit_base_url:
        return explicit_base_url

    kamiwaza_spec = ((obj.get("spec") or {}).get("kamiwaza") or {})
    for key in ("apiUrl", "publicApiUrl"):
        value = str(kamiwaza_spec.get(key) or "").strip()
        if value:
            return value

    raise RuntimeError(
        "Unable to derive KAMIWAZA_BASE_URL from spec.kamiwaza.{apiUrl,publicApiUrl}; "
        "pass --kamiwaza-base-url explicitly."
    )


def _patch_spec(
    obj: Dict[str, Any],
    backend_extra_env: Dict[str, str],
    backend_base_url: str,
) -> Dict[str, Any]:
    spec = obj.setdefault("spec", {})

    kamiwaza = spec.setdefault("kamiwaza", {})
    kamiwaza["tlsRejectUnauthorized"] = "1"

    networking = spec.setdefault("networking", {})
    network_policy = networking.setdefault("networkPolicy", {})
    network_policy["allowExternalAccess"] = True
    if "enabled" not in network_policy:
        network_policy["enabled"] = True

    services = spec.get("services") or []
    if not isinstance(services, list) or not services:
        raise RuntimeError("spec.services missing or invalid on live KamiwazaExtension")

    found_backend = False
    found_controller = False
    for service in services:
        name = service.get("name")
        if name == "backend":
            _patch_service(
                service,
                {
                    **BACKEND_VERIFY_ENV,
                    "KAMIWAZA_BASE_URL": backend_base_url,
                    **backend_extra_env,
                },
            )
            found_backend = True
        elif name == "sandbox-controller":
            _patch_service(service, {})
            found_controller = True

    if not found_backend:
        raise RuntimeError("service 'backend' not found in live Kaizen extension")
    if not found_controller:
        raise RuntimeError("service 'sandbox-controller' not found in live Kaizen extension")

    metadata = obj.get("metadata") or {}
    cleaned: Dict[str, Any] = {
        "apiVersion": obj["apiVersion"],
        "kind": obj["kind"],
        "metadata": {
            "name": metadata["name"],
            "namespace": metadata.get("namespace", EXT_NS),
        },
        "spec": spec,
    }
    if metadata.get("labels"):
        cleaned["metadata"]["labels"] = metadata["labels"]
    if metadata.get("annotations"):
        cleaned["metadata"]["annotations"] = metadata["annotations"]
    return cleaned


def _warn_if_internal_https_api_url(obj: Dict[str, Any], backend_base_url: str) -> None:
    """Warn when verify-on will break the Kaizen backend's own API base URL.

    Kaizen's backend uses KAMIWAZA_BASE_URL, not KAMIWAZA_API_URL directly. This
    patcher mirrors a platform URL into KAMIWAZA_BASE_URL. If that chosen URL is
    an internal HTTPS service hostname (e.g. https://traefik.kamiwaza.svc.cluster.local/api),
    verification ON will fail TLS hostname validation even though the CA is
    trusted. Surface it loudly before patching.
    """
    if not backend_base_url.startswith("https://"):
        return
    try:
        netloc = backend_base_url.split("/", 3)[2]
    except IndexError:
        netloc = ""
    if ".svc" not in netloc and ".cluster.local" not in netloc:
        return  # public/external HTTPS host; assume cert-matching
    sys.stderr.write(
        "\nWARNING: chosen KAMIWAZA_BASE_URL is an internal HTTPS hostname:\n"
        f"    {backend_base_url}\n"
        "Turning verification ON (this patcher) will make the Kaizen backend's\n"
        "calls to that URL fail TLS hostname validation, because the Traefik\n"
        "serving cert is for *.kamiwaza.test, not an internal *.svc name.\n"
        "Fix it cert-matching:\n"
        "  - rerun with --kamiwaza-base-url https://kamiwaza.test/api, or\n"
        "  - add the internal hostname to the Traefik cert SANs.\n"
        "Then run verify-kaizen.sh (step 3a fails closed on this exact mismatch).\n\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch a live Kaizen KamiwazaExtension CR for the 0.13.0 trust-bundle hotfix."
    )
    parser.add_argument("name", help="KamiwazaExtension name, e.g. kaizen-a1b2c3d4")
    parser.add_argument(
        "--namespace",
        default=EXT_NS,
        help=f"Extension namespace (default: {EXT_NS})",
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="Print the patched manifest instead of applying it",
    )
    parser.add_argument(
        "--https-proxy",
        default=os.environ.get("HTTPS_PROXY", ""),
        help="Optional HTTPS proxy URL to inject into the Kaizen backend",
    )
    parser.add_argument(
        "--http-proxy",
        default=os.environ.get("HTTP_PROXY", ""),
        help="Optional HTTP proxy URL to inject into the Kaizen backend",
    )
    parser.add_argument(
        "--no-proxy",
        default=os.environ.get("NO_PROXY", ""),
        help="Optional NO_PROXY value to inject into the Kaizen backend",
    )
    parser.add_argument(
        "--kamiwaza-base-url",
        default=os.environ.get("KAMIWAZA_BASE_URL", ""),
        help=(
            "Explicit KAMIWAZA_BASE_URL for the Kaizen backend. "
            "Defaults to spec.kamiwaza.apiUrl, then publicApiUrl."
        ),
    )
    args = parser.parse_args()

    obj = _load_extension(args.name, args.namespace)
    backend_base_url = _derive_backend_base_url(obj, args.kamiwaza_base_url)
    _warn_if_internal_https_api_url(obj, backend_base_url)
    backend_extra_env = {
        key: value
        for key, value in {
            "HTTPS_PROXY": args.https_proxy,
            "HTTP_PROXY": args.http_proxy,
            "NO_PROXY": args.no_proxy,
        }.items()
        if value
    }
    cleaned = _patch_spec(obj, backend_extra_env, backend_base_url)
    rendered = json.dumps(cleaned, indent=2) + "\n"

    if args.print_only:
        sys.stdout.write(rendered)
        return 0

    _run("kubectl", "apply", "-f", "-", input_text=rendered)
    print(f"patched Kaizen extension {args.namespace}/{args.name}")
    print(f"set backend KAMIWAZA_BASE_URL={backend_base_url}")
    if backend_extra_env:
        print(f"injected backend proxy env: {', '.join(sorted(backend_extra_env))}")
    print("next: open or resume a Kaizen conversation, then run verify-kaizen.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
