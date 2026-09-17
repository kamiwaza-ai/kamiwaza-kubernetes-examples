import contextlib
import http.client
import json
import os
import ssl


DEPENDENCY_NAMESPACE = "platform-validation-dependencies"
CA = "/ca/ca.crt"
CERT = "/tls/tls.crt"
KEY = "/tls/tls.key"


def tls_context():
    context = ssl.create_default_context(cafile=CA)
    context.load_cert_chain(CERT, KEY)
    return context


def verify_edge():
    # contextlib.closing, because an http.client connection is not a context
    # manager: `with HTTPSConnection(...)` raises TypeError before any request
    # is made, which reads as a failed fixture rather than as a typo here.
    with contextlib.closing(
        http.client.HTTPSConnection(
            f"cac-piv-edge.{DEPENDENCY_NAMESPACE}.svc.cluster.local",
            8443,
            context=tls_context(),
            timeout=10,
        )
    ) as edge:
        edge.request(
            "GET",
            "/api/auth/cac/login",
            headers={"X-User": "caller-controlled"},
        )
        response = edge.getresponse()
        result = json.loads(response.read())
    if response.status != 200 or result != {
        "clientCertificate": "verified",
        "inboundIdentityHeadersRemoved": True,
        "pathRestricted": True,
    }:
        raise RuntimeError(f"unexpected edge result: {result}")


def verify_stream():
    with contextlib.closing(
        http.client.HTTPConnection(
            f"resumable-stream.{DEPENDENCY_NAMESPACE}.svc.cluster.local",
            8080,
            timeout=10,
        )
    ) as stream:
        stream.request("GET", "/stream")
        first = stream.getresponse().read().decode()
        stream.request("GET", "/stream", headers={"Last-Event-ID": "3"})
        second = stream.getresponse().read().decode()
    if "id: 3" not in first:
        raise RuntimeError("initial stream did not reach checkpoint 3")
    if "id: 4" not in second or "id: 3" in second:
        raise RuntimeError("stream did not resume after checkpoint 3")


def verify_proxy():
    target = f"mutual-tls-destination.{DEPENDENCY_NAMESPACE}.svc.cluster.local"
    connection = http.client.HTTPSConnection(
        f"egress-proxy.{DEPENDENCY_NAMESPACE}.svc.cluster.local",
        3128,
        context=tls_context(),
        timeout=10,
    )
    connection.set_tunnel(target, 8443)
    connection.request("GET", "/probe")
    response = connection.getresponse()
    if response.status != 200 or json.loads(response.read()) != {
        "clientCertificate": "verified"
    }:
        raise RuntimeError("approved proxy path failed")

    try:
        direct = http.client.HTTPSConnection(target, 8443, context=tls_context(), timeout=3)
        direct.request("GET", "/probe")
        direct.getresponse()
    except OSError:
        return
    raise RuntimeError("direct egress bypassed enforcing proxy")


if os.environ["VALIDATION_MODE"] == "dependencies":
    verify_edge()
    verify_stream()
else:
    verify_proxy()
