#!/usr/bin/env python3
"""Serve the built-in example login for manual fill proof. No values are logged."""
import argparse
import hmac
import http.server
import ssl
from pathlib import Path
from urllib.parse import parse_qs


class ExampleLogin(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, body, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path not in ("/", "/login"):
            self.respond(b"Not found.", 404)
            return
        self.respond(Path(__file__).with_name("browser_plugin_login.html").read_bytes())

    def do_POST(self):
        if self.path != "/login":
            self.respond(b"Not found.", 404)
            return
        fields = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode("utf-8"))
        accepted = (hmac.compare_digest(fields.get("username", [""])[0], "example@example.com")
                    and hmac.compare_digest(fields.get("password", [""])[0], "example-password"))
        self.respond(b"<!doctype html><title>Fill proof</title><h1>" +
                     (b"Example login accepted." if accepted else b"Example login did not match.") + b"</h1>")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cert", required=True, type=Path)
    parser.add_argument("--key", required=True, type=Path)
    arguments = parser.parse_args()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(arguments.cert, arguments.key)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 8443), ExampleLogin)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("Open https://example.com:8443/login in each browser.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
