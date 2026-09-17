import json
import os
import select
import socket
import socketserver
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MODE = os.environ["FIXTURE_MODE"]
IDENTITY_HEADERS = {
    "client-cert",
    "client-cert-chain",
    "x-forwarded-client-cert",
    "x-client-cert",
    "x-client-verify",
    "x-user",
}


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
        elif MODE == "stream" and self.path == "/stream":
            self._stream()
        elif MODE == "mtls" and self.path == "/probe":
            self._mtls_probe()
        elif MODE == "edge":
            self._edge()
        else:
            self.send_error(404)

    def do_POST(self):
        if MODE == "edge":
            self._edge()
        else:
            self.send_error(404)

    def _stream(self):
        try:
            previous = int(self.headers.get("Last-Event-ID", "0"))
        except ValueError:
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        for event_id in range(previous + 1, previous + 4):
            self.wfile.write(f"id: {event_id}\ndata: event-{event_id}\n\n".encode())
            self.wfile.flush()

    def _mtls_probe(self):
        if not self.connection.getpeercert(binary_form=True):
            self.send_error(401)
            return
        payload = b'{"clientCertificate":"verified"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _edge(self):
        if self.path != "/api/auth/cac/login":
            self.send_error(404)
            return
        certificate = self.connection.getpeercert(binary_form=True)
        if not certificate:
            self.send_error(401)
            return
        spoofed = any(name.lower() in IDENTITY_HEADERS for name in self.headers)
        payload = json.dumps(
            {
                "clientCertificate": "verified",
                "inboundIdentityHeadersRemoved": spoofed,
                "pathRestricted": True,
            }
        ).encode()
        status = 200
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class ProxyHandler(socketserver.StreamRequestHandler):
    def handle(self):
        first_line = self.rfile.readline(8192).decode("ascii", "strict").strip()
        if first_line.startswith("GET /healthz "):
            self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            return
        method, target, _version = first_line.split(" ", 2)
        self._discard_headers()
        if method != "CONNECT" or target != os.environ["PROXY_ALLOWED_TARGET"]:
            self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        host, port = target.rsplit(":", 1)
        upstream = socket.create_connection((host, int(port)), timeout=10)
        self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        try:
            self._relay(upstream)
        finally:
            upstream.close()

    def _discard_headers(self):
        while self.rfile.readline(8192) not in (b"\r\n", b"\n", b""):
            pass

    def _relay(self, upstream):
        sockets = [self.connection, upstream]
        while readable := select.select(sockets, [], [], 30)[0]:
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                destination = upstream if source is self.connection else self.connection
                destination.sendall(data)


def serve_http():
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), FixtureHandler)
    if MODE in {"mtls", "edge"}:
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.verify_mode = ssl.CERT_REQUIRED
        context.load_verify_locations("/ca/ca.crt")
        context.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if MODE == "proxy":
    with socketserver.ThreadingTCPServer(("0.0.0.0", 3128), ProxyHandler) as proxy:
        proxy.daemon_threads = True
        proxy.serve_forever()
else:
    serve_http()
