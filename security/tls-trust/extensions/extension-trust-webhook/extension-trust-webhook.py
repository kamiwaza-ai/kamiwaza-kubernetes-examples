#!/usr/bin/env python3
"""Mutating admission webhook: inject corporate-CA trust into every extension pod.

This makes ALL Kamiwaza extension workloads trust a corporate CA dynamically — declared
service pods of any extension (apps, tools, MCP servers) AND the sandbox pods that
sandbox-spawning extensions (e.g. Kaizen) create — with no per-extension patching and no
controller-code overlay. It is NOT specific to Kaizen or to sandboxes: it keys on the pod's
namespace + extension labels, so any extension that runs pods in the watched namespaces is
covered automatically, including ones deployed after the webhook is installed.

To each matched pod it adds, idempotently:
  - a volume `kamiwaza-trust-bundle` sourcing ConfigMap `kamiwaza-trust-bundle`
    (key `ca-certificates.crt`, optional: true), and
  - a read-only subPath volumeMount of that key at `/etc/ssl/certs/ca-certificates.crt`
    on every container, and
  - the CA env vars (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `AWS_CA_BUNDLE`,
    `NODE_EXTRA_CA_CERTS`) pointing at that path — added ONLY IF the container does not
    already set them (never overrides an image's own value).

WHY env vars (not just the mount): replacing /etc/ssl/certs/ca-certificates.crt covers code
that reads the OS trust store, but Python `requests`/`httpx` use `certifi` and Node uses its
own bundled CAs — they only pick up the corporate CA via `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE`
/`NODE_EXTRA_CA_CERTS`. So the env is load-bearing for real extension runtimes, not cosmetic.

Config-only / airgap: pure Python standard library, runs on any in-cluster image with
python3, logic in a ConfigMap, long-lived self-signed serving cert. The webhook is scoped
by namespace + label and uses `failurePolicy: Ignore`, so a webhook outage degrades to
"extension pod without injected trust" (prior behavior) and never blocks pod creation.

Env:
  BUNDLE_CONFIGMAP  ConfigMap name to mount   (default: kamiwaza-trust-bundle)
  BUNDLE_KEY        key in that ConfigMap     (default: ca-certificates.crt)
  BUNDLE_MOUNT_PATH in-pod mount path         (default: /etc/ssl/certs/ca-certificates.crt)
  VOLUME_NAME       pod volume name to add    (default: kamiwaza-trust-bundle)
  CA_ENV_VARS       comma-separated env names to set to BUNDLE_MOUNT_PATH (only-if-absent);
                    empty string disables env injection (mount-only).
                    (default: SSL_CERT_FILE,REQUESTS_CA_BUNDLE,AWS_CA_BUNDLE,NODE_EXTRA_CA_CERTS)
  TLS_CERT_FILE / TLS_KEY_FILE / LISTEN_PORT  (defaults: /tls/tls.crt, /tls/tls.key, 8443)
"""

from __future__ import annotations

import base64
import json
import os
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BUNDLE_CONFIGMAP = os.environ.get("BUNDLE_CONFIGMAP", "kamiwaza-trust-bundle")
BUNDLE_KEY = os.environ.get("BUNDLE_KEY", "ca-certificates.crt")
BUNDLE_MOUNT_PATH = os.environ.get("BUNDLE_MOUNT_PATH", "/etc/ssl/certs/ca-certificates.crt")
VOLUME_NAME = os.environ.get("VOLUME_NAME", "kamiwaza-trust-bundle")
_DEFAULT_ENV = "SSL_CERT_FILE,REQUESTS_CA_BUNDLE,AWS_CA_BUNDLE,NODE_EXTRA_CA_CERTS"
CA_ENV_VARS = [v.strip() for v in os.environ.get("CA_ENV_VARS", _DEFAULT_ENV).split(",") if v.strip()]
TLS_CERT_FILE = os.environ.get("TLS_CERT_FILE", "/tls/tls.crt")
TLS_KEY_FILE = os.environ.get("TLS_KEY_FILE", "/tls/tls.key")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8443"))


def build_patch(pod_spec: dict) -> list:
    """Return a JSONPatch (RFC 6902) adding the trust-bundle volume, mounts, and CA env.

    Idempotent: the volume is added only if absent; per container the mount is added only if
    absent, and each CA env var is added only if that container does not already define it
    (so an image's own SSL_CERT_FILE etc. is never overridden). Handles missing
    volumes/volumeMounts/env arrays. Pure function — unit-testable without a cluster.
    """
    patch: list = []

    volumes = pod_spec.get("volumes")
    has_volume = isinstance(volumes, list) and any(
        isinstance(v, dict) and v.get("name") == VOLUME_NAME for v in volumes
    )
    desired_volume = {
        "name": VOLUME_NAME,
        "configMap": {
            "name": BUNDLE_CONFIGMAP,
            "optional": True,
            "items": [{"key": BUNDLE_KEY, "path": BUNDLE_KEY}],
        },
    }
    if not has_volume:
        if isinstance(volumes, list):
            patch.append({"op": "add", "path": "/spec/volumes/-", "value": desired_volume})
        else:
            patch.append({"op": "add", "path": "/spec/volumes", "value": [desired_volume]})

    desired_mount = {
        "name": VOLUME_NAME,
        "mountPath": BUNDLE_MOUNT_PATH,
        "subPath": BUNDLE_KEY,
        "readOnly": True,
    }
    for i, container in enumerate(pod_spec.get("containers", []) or []):
        # --- volume mount (only if absent) ---
        mounts = container.get("volumeMounts")
        mounted = isinstance(mounts, list) and any(
            isinstance(m, dict)
            and (m.get("name") == VOLUME_NAME or m.get("mountPath") == BUNDLE_MOUNT_PATH)
            for m in mounts
        )
        if not mounted:
            if isinstance(mounts, list):
                patch.append({"op": "add", "path": f"/spec/containers/{i}/volumeMounts/-", "value": desired_mount})
            else:
                patch.append({"op": "add", "path": f"/spec/containers/{i}/volumeMounts", "value": [desired_mount]})

        # --- CA env vars (only-if-absent; never override the image's own values) ---
        env = container.get("env")
        existing = {e.get("name") for e in env if isinstance(e, dict)} if isinstance(env, list) else set()
        missing = [{"name": name, "value": BUNDLE_MOUNT_PATH} for name in CA_ENV_VARS if name not in existing]
        if missing:
            if isinstance(env, list):
                for entry in missing:
                    patch.append({"op": "add", "path": f"/spec/containers/{i}/env/-", "value": entry})
            else:
                patch.append({"op": "add", "path": f"/spec/containers/{i}/env", "value": missing})

    return patch


def review_response(req: dict) -> dict:
    """Build the AdmissionReview response for a v1 AdmissionReview request."""
    request = (req or {}).get("request") or {}
    uid = request.get("uid", "")
    response = {"uid": uid, "allowed": True}
    try:
        pod = request.get("object") or {}
        spec = pod.get("spec") or {}
        patch = build_patch(spec)
        if patch:
            response["patchType"] = "JSONPatch"
            response["patch"] = base64.b64encode(json.dumps(patch).encode()).decode()
    except Exception as exc:  # never fail closed — allow the pod unmutated
        response["warnings"] = [f"extension-trust-webhook: skipped injection: {exc}"]
    return {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": response,
    }


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        # The API server appends ?timeout=<n>s; compare on the path only.
        if self.path.split("?", 1)[0] in ("/healthz", "/readyz"):
            self._send(200, b'{"ok":true}')
        else:
            self._send(404)

    def do_POST(self):  # noqa: N802
        # self.path includes the query string (the API server calls /mutate?timeout=5s).
        if self.path.split("?", 1)[0] != "/mutate":
            self._send(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length) or b"{}")
            self._send(200, json.dumps(review_response(req)).encode())
        except Exception as exc:
            self._send(200, json.dumps({
                "apiVersion": "admission.k8s.io/v1",
                "kind": "AdmissionReview",
                "response": {"uid": "", "allowed": True, "warnings": [f"webhook error: {exc}"]},
            }).encode())

    def log_message(self, *args):  # quiet (suppress per-request access logs)
        pass


def main() -> None:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(TLS_CERT_FILE, TLS_KEY_FILE)
    httpd = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"extension-trust-webhook listening on :{LISTEN_PORT} "
          f"(cm={BUNDLE_CONFIGMAP} key={BUNDLE_KEY} path={BUNDLE_MOUNT_PATH} env={','.join(CA_ENV_VARS) or '(none)'})",
          flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
