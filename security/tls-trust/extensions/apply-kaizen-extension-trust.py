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


def _cert_matching_api_url(kamiwaza_spec: Dict[str, Any]) -> str | None:
    """Return a cert-matching KAMIWAZA_API_URL override, or None if not needed.

    When the platform sets spec.kamiwaza.apiUrl to an internal HTTPS service
    hostname (e.g. https://traefik.kamiwaza.svc.cluster.local/api), turning
    verification ON makes the backend's calls to its own API fail TLS hostname
    validation — the Traefik serving cert is for the public domain, not an
    internal *.svc name. The fix is to point the backend at the cert-matching
    public origin (spec.kamiwaza.publicApiUrl, e.g. https://kamiwaza.test/api).

    This must be set as a DIRECT backend env: the operator renders the internal
    value into the <deployment-id>-config ConfigMap consumed via envFrom, and a
    direct env overrides envFrom for the same key. Patching only
    spec.kamiwaza.apiUrl does NOT change the already-rendered ConfigMap, so the
    stale internal value would still reach the pod.
    """
    api_url = (kamiwaza_spec.get("apiUrl") or "").strip()
    if not api_url.startswith("https://"):
        return None  # http:// is not subject to TLS verification; leave it
    try:
        netloc = api_url.split("/", 3)[2]
    except IndexError:
        netloc = ""
    if ".svc" not in netloc and ".cluster.local" not in netloc:
        return None  # already a public/cert-matching HTTPS host
    public = (kamiwaza_spec.get("publicApiUrl") or "").strip()
    if not public:
        origin = (kamiwaza_spec.get("origin") or "").strip().rstrip("/")
        public = f"{origin}/api" if origin else ""
    return public or None


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


def _patch_spec(obj: Dict[str, Any], backend_extra_env: Dict[str, str]) -> Dict[str, Any]:
    spec = obj.setdefault("spec", {})

    kamiwaza = spec.setdefault("kamiwaza", {})
    kamiwaza["tlsRejectUnauthorized"] = "1"

    # When apiUrl is an internal HTTPS .svc host, verify-ON would break the
    # backend's calls to its own API. Repoint it (CR field for documentation,
    # plus a direct backend env below that actually wins over the envFrom value).
    api_url_override = _cert_matching_api_url(kamiwaza)
    if api_url_override:
        kamiwaza["apiUrl"] = api_url_override

    networking = spec.setdefault("networking", {})
    network_policy = networking.setdefault("networkPolicy", {})
    network_policy["allowExternalAccess"] = True
    if "enabled" not in network_policy:
        network_policy["enabled"] = True

    services = spec.get("services") or []
    if not isinstance(services, list) or not services:
        raise RuntimeError("spec.services missing or invalid on live KamiwazaExtension")

    backend_env = {**BACKEND_VERIFY_ENV, **backend_extra_env}
    if api_url_override:
        # Direct backend env wins over the stale internal value from envFrom.
        backend_env["KAMIWAZA_API_URL"] = api_url_override

    found_backend = False
    found_controller = False
    for service in services:
        name = service.get("name")
        if name == "backend":
            _patch_service(service, backend_env)
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


def _warn_if_internal_https_api_url(obj: Dict[str, Any]) -> None:
    """Report when the backend's KAMIWAZA_API_URL is being auto-corrected.

    The platform sometimes sets spec.kamiwaza.apiUrl to an internal HTTPS service
    hostname (e.g. https://traefik.kamiwaza.svc.cluster.local/api). That hostname
    does NOT match the Traefik serving cert (*.kamiwaza.test), so turning
    verification ON would make the extension's calls to its own API fail TLS
    hostname validation even though the CA is trusted. The patcher now repoints
    it to the cert-matching public origin automatically (see
    _cert_matching_api_url); this just surfaces what it did.
    """
    kamiwaza = (obj.get("spec") or {}).get("kamiwaza") or {}
    api_url = kamiwaza.get("apiUrl") or ""
    if not api_url.startswith("https://"):
        return
    try:
        netloc = api_url.split("/", 3)[2]
    except IndexError:
        netloc = ""
    if ".svc" not in netloc and ".cluster.local" not in netloc:
        return  # public/external HTTPS host; assume cert-matching
    override = _cert_matching_api_url(kamiwaza)
    if override:
        sys.stderr.write(
            "\nNOTE: spec.kamiwaza.apiUrl is an internal HTTPS hostname:\n"
            f"    {api_url}\n"
            "Verify-ON would break the extension's calls to its own API (the Traefik\n"
            "serving cert is for the public domain, not an internal *.svc name).\n"
            f"Auto-correcting the backend KAMIWAZA_API_URL to: {override}\n"
            "(set both on spec.kamiwaza.apiUrl and as a direct backend env so it\n"
            "wins over the stale value rendered into the envFrom ConfigMap).\n\n"
        )
    else:
        sys.stderr.write(
            "\nWARNING: spec.kamiwaza.apiUrl is an internal HTTPS hostname:\n"
            f"    {api_url}\n"
            "but no spec.kamiwaza.publicApiUrl/origin is set to repoint it to, so it\n"
            "cannot be auto-corrected. Verify-ON will break the extension's calls to\n"
            "its own API. Set a cert-matching public origin, then re-run.\n\n"
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
    args = parser.parse_args()

    obj = _load_extension(args.name, args.namespace)
    _warn_if_internal_https_api_url(obj)
    backend_extra_env = {
        key: value
        for key, value in {
            "HTTPS_PROXY": args.https_proxy,
            "HTTP_PROXY": args.http_proxy,
            "NO_PROXY": args.no_proxy,
        }.items()
        if value
    }
    cleaned = _patch_spec(obj, backend_extra_env)
    rendered = json.dumps(cleaned, indent=2) + "\n"

    if args.print_only:
        sys.stdout.write(rendered)
        return 0

    _run("kubectl", "apply", "-f", "-", input_text=rendered)
    print(f"patched Kaizen extension {args.namespace}/{args.name}")
    if backend_extra_env:
        print(f"injected backend proxy env: {', '.join(sorted(backend_extra_env))}")
    print("next: open or resume a Kaizen conversation, then run verify-kaizen.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
