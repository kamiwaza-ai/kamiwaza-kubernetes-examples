"""Prove one extension service reaches the platform through the projected origin.

The origin comes from KAMIWAZA_PLATFORM_GATEWAY_URL, which the platform
projects into every platform-integrated extension service. Nothing here
constructs, overrides, or falls back to another address: an extension that
guesses a platform address is the defect this variable exists to remove.

The Host header carries the platform domain, because the published route is
attached to that hostname while the transport dials a Service. Both halves are
the contract: change either and the callback stops being the registered route.

An unauthenticated callback is expected to be refused. A refusal is proof the
request reached the platform; what would not be proof is a gateway 404, a 503,
or a timeout, so those fail. This prober carries no credential at all, by
design.
"""

import contextlib
import http.client
import json
import os
import socket
import ssl
import sys
import urllib.parse

ORIGIN = os.environ.get("KAMIWAZA_PLATFORM_GATEWAY_URL", "")
DOMAIN = os.environ["PLATFORM_DOMAIN"]
SERVICE = os.environ["SERVICE_NAME"]

# One path per published route family: the legacy application API and the
# native governed endpoint. They are served by different backends behind the
# same gateway, so a result for one says nothing about the other.
PATHS = {"legacy": "/api/runtime/models", "native": "/v1/models"}

# Reached the platform: it answered with a decision of its own.
REACHED = {200, 401, 403, 404}
# The gateway answered instead of the platform, or nothing did.
NOT_REACHED = {502, 503, 504}


class GatewayConnection(http.client.HTTPSConnection):
    """Dial the Service the platform named; handshake as the platform domain.

    Two names, both required, and Python ties them together by default. The
    connection goes to the Service address immutable policy names, and the TLS
    handshake asks for the platform domain, because the gateway listener holds
    a certificate for the domain and resets a handshake that asks for the
    Service name. The Host header is the domain for the same reason: the
    published route is attached to that hostname.
    """

    def __init__(self, address, port, domain, context, timeout):
        super().__init__(domain, port, context=context, timeout=timeout)
        self._address = address

    def connect(self):
        self.sock = self._context.wrap_socket(
            socket.create_connection((self._address, self.port), timeout=self.timeout),
            server_hostname=self.host,
        )


def probe(path):
    parsed = urllib.parse.urlsplit(ORIGIN)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    if parsed.scheme == "https":
        # The authority comes from the trust distribution the platform
        # projects, read from the variable it sets rather than a path this
        # prober picks.
        context = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or None)
        connection = GatewayConnection(parsed.hostname, port, DOMAIN, context, 10)
    else:
        connection = http.client.HTTPConnection(parsed.hostname, port, timeout=10)
    with contextlib.closing(connection) as client:
        client.request("GET", path, headers={"Host": DOMAIN, "Accept": "application/json"})
        response = client.getresponse()
        response.read()
        return response.status


def main():
    if not ORIGIN:
        print(json.dumps({"service": SERVICE, "error": "no projected callback origin"}))
        return 1
    results = {}
    for family, path in PATHS.items():
        try:
            results[family] = probe(path)
        except OSError as error:
            results[family] = type(error).__name__
    record = {"service": SERVICE, "origin": ORIGIN, "results": results}
    print(json.dumps(record), flush=True)
    for family, status in results.items():
        if status in REACHED:
            continue
        print(
            json.dumps({"service": SERVICE, "family": family, "unreached": status}),
            flush=True,
        )
        return 1
    return 0


if __name__ == "__main__":
    # Keep answering, because a Deployment that exits is a restart loop rather
    # than a result. The first pass decides the exit status of the check the
    # verifier reads from the log.
    status = main()
    if status != 0:
        sys.exit(status)
    import time

    while True:
        time.sleep(3600)
