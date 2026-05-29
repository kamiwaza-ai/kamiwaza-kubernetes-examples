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

BACKEND_VERIFY_ENV = {
    "AGENT_DISABLE_SSL_VERIFY": "false",
    "KAMIWAZA_VERIFY_SSL": "true",
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


def _patch_spec(obj: Dict[str, Any]) -> Dict[str, Any]:
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
            _patch_service(service, BACKEND_VERIFY_ENV)
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
    args = parser.parse_args()

    obj = _load_extension(args.name, args.namespace)
    cleaned = _patch_spec(obj)
    rendered = json.dumps(cleaned, indent=2) + "\n"

    if args.print_only:
        sys.stdout.write(rendered)
        return 0

    _run("kubectl", "apply", "-f", "-", input_text=rendered)
    print(f"patched Kaizen extension {args.namespace}/{args.name}")
    print("next: open or resume a Kaizen conversation, then run verify-kaizen.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
