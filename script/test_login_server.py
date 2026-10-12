#!/usr/bin/env python3
"""Serve an isolated fake password and verification-code login using only stdlib.

The generated fixture contains synthetic secrets and is written with mode 0600.
Only its path, loopback URLs, and boolean/count results are written to stdout.
Request bodies, submitted credentials, and session cookies are never logged.
"""

import argparse
import base64
import hashlib
import hmac
import html
import http.cookies
import http.server
import json
import os
from pathlib import Path
import secrets
import struct
import tempfile
import threading
import time
import urllib.parse


def verification_code(secret, timestamp):
    digest = hmac.new(secret, struct.pack(">Q", int(timestamp) // 30), hashlib.sha1).digest()
    offset = digest[-1] & 15
    return f"{(struct.unpack('>I', digest[offset:offset + 4])[0] & 0x7fffffff) % 1000000:06d}"


def private_json(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(value, output, indent=2)
        output.write("\n")


class LoginServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, example_login=False):
        super().__init__(("127.0.0.1", port), LoginHandler)
        self.example_login = example_login
        self.lock = threading.Lock()
        self.origin = f"http://127.0.0.1:{self.server_port}"
        self.started_at = int(time.time())
        self.totp_secret = secrets.token_bytes(20)
        self.fixture = {
            "origin": self.origin,
            "item_id": "00000000-0000-0000-0000-000000000091",
            "username": f"synthetic-{secrets.token_hex(6)}@example.invalid",
            "password": "Synthetic-only-" + secrets.token_urlsafe(30),
            "totp_secret": base64.b64encode(self.totp_secret).decode("ascii"),
            "totp_secret_encoding": "base64",
            "started_at": self.started_at,
            "policy": "ask",
            "authorization": "allow",
        }
        if example_login:
            self.fixture.update(username="example@example.com", password="example-password")
        self.pending_sessions = set()
        self.authenticated_sessions = set()
        self.results = {
            "password_posts": 0,
            "password_accepted": 0,
            "password_rejected": 0,
            "verification_posts": 0,
            "verification_accepted": 0,
            "verification_rejected": 0,
            "authenticated_visits": 0,
            "unrelated_field_received_text": False,
            "password_present_in_otp_form": False,
        }



class LoginHandler(http.server.BaseHTTPRequestHandler):
    server_version = "SyntheticLogin"

    def log_message(self, format, *args):
        pass

    def log_error(self, format, *args):
        pass

    def send_document(self, status, body, content_type="text/html; charset=utf-8", cookie=None):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; form-action 'self'; base-uri 'none'; style-src 'unsafe-inline'")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(payload)

    def redirect(self, path, cookie=None):
        self.send_response(303)
        self.send_header("Location", path)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def document(self, title, body):
        return ("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\">"
                f"<title>{html.escape(title)}</title><style>"
                "body{font:18px system-ui;max-width:42rem;margin:4rem auto;padding:1rem}"
                "label,input,textarea,button{display:block;margin:.7rem 0}"
                "input,textarea,button{font:inherit;padding:.5rem}"
                "</style><body>" + body + "</body></html>")

    def cookies(self):
        result = http.cookies.SimpleCookie()
        try:
            result.load(self.headers.get("Cookie", ""))
        except http.cookies.CookieError:
            return http.cookies.SimpleCookie()
        return result

    def cookie_value(self, name):
        value = self.cookies().get(name)
        return value.value if value else None

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/results":
            with self.server.lock:
                results = dict(self.server.results)
            self.send_document(200, json.dumps(results), "application/json")
        elif parsed.path == "/health":
            self.send_document(200, '{"ready":true}', "application/json")
        elif parsed.path in ("/", "/login"):
            self.send_document(200, self.document("Synthetic sign in", f"""
                <h1>Synthetic sign in</h1>
                <p>This page uses synthetic test credentials only.</p>
                <form method="post" action="/password">
                  <label for="unrelated">Unrelated notes</label>
                  <textarea id="unrelated" name="unrelated" autofocus></textarea>
                  <label for="username">Username</label>
                  <input id="username" name="username" autocomplete="username" required>
                  <label for="password">Password</label>
                  <input id="password" name="password" type="password" autocomplete="current-password" required>
                  <button id="sign-in" type="submit">Sign in</button>
                </form>
            """))
        elif parsed.path == "/verify":
            if self.cookie_value("pending") not in self.server.pending_sessions:
                self.redirect("/login")
                return
            self.send_document(200, self.document("Verify sign in", """
                <h1>Verify sign in</h1>
                <form method="post" action="/verify">
                  <label for="unrelated">Unrelated notes</label>
                  <textarea id="unrelated" name="unrelated" autofocus></textarea>
                  <label for="verification-code">Verification code</label>
                  <input id="verification-code" name="code" type="text" inputmode="numeric"
                         autocomplete="one-time-code" required pattern="[0-9]{6}">
                  <button id="verify" type="submit">Verify</button>
                </form>
            """))
        elif parsed.path == "/account":
            if self.cookie_value("session") not in self.server.authenticated_sessions:
                self.redirect("/login")
                return
            with self.server.lock:
                self.server.results["authenticated_visits"] += 1
            self.send_document(200, self.document("Account", """
                <h1>Signed in</h1><p id="authenticated">Synthetic account access succeeded.</p>
            """))
        else:
            self.send_document(404, self.document("Not found", "<h1>Not found</h1>"))

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 < length <= 16384:
            self.send_document(400, self.document("Invalid request", "<h1>Invalid request</h1>"))
            return
        body = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", errors="replace"))
        field = lambda name: body.get(name, [""])[0]
        parsed = urllib.parse.urlsplit(self.path)
        with self.server.lock:
            if field("unrelated"):
                self.server.results["unrelated_field_received_text"] = True
        if parsed.path == "/password":
            matched = (hmac.compare_digest(field("username"), self.server.fixture["username"])
                       and hmac.compare_digest(field("password"), self.server.fixture["password"]))
            with self.server.lock:
                self.server.results["password_posts"] += 1
                self.server.results["password_accepted" if matched else "password_rejected"] += 1
            if not matched:
                self.send_document(401, self.document("Sign in failed", "<h1>Sign in failed</h1>"))
            elif self.server.example_login:
                session = secrets.token_urlsafe(24)
                with self.server.lock:
                    self.server.authenticated_sessions.add(session)
                self.redirect("/account", f"session={session}; HttpOnly; SameSite=Strict; Path=/")
            else:
                pending = secrets.token_urlsafe(24)
                with self.server.lock:
                    self.server.pending_sessions.add(pending)
                self.redirect("/verify", f"pending={pending}; HttpOnly; SameSite=Strict; Path=/")
        elif parsed.path == "/verify":
            pending = self.cookie_value("pending")
            if pending not in self.server.pending_sessions:
                self.send_document(401, self.document("Session expired", "<h1>Session expired</h1>"))
                return
            expected = [verification_code(self.server.totp_secret, time.time() + shift)
                        for shift in (-30, 0, 30)]
            matched = any(hmac.compare_digest(field("code"), value) for value in expected)
            with self.server.lock:
                self.server.results["verification_posts"] += 1
                self.server.results["verification_accepted" if matched else "verification_rejected"] += 1
                if field("password"):
                    self.server.results["password_present_in_otp_form"] = True
            if not matched:
                self.send_document(401, self.document("Verification failed", "<h1>Verification failed</h1>"))
            else:
                session = secrets.token_urlsafe(24)
                with self.server.lock:
                    self.server.pending_sessions.discard(pending)
                    self.server.authenticated_sessions.add(session)
                self.redirect("/account", f"session={session}; HttpOnly; SameSite=Strict; Path=/")
        else:
            self.send_document(400, self.document("Wrong destination", "<h1>Wrong destination</h1>"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, help="New private fixture directory; defaults to a temporary directory")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--example", action="store_true", help="Use the built-in example login without a verification-code step")
    arguments = parser.parse_args()
    if arguments.directory:
        directory = arguments.directory.resolve()
        directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    else:
        directory = Path(tempfile.mkdtemp(prefix="agent-keyring-login-"))
    server = LoginServer(arguments.port, example_login=arguments.example)
    config_path = directory / "fixture.json"
    private_json(config_path, server.fixture)
    print(json.dumps({"origin": server.origin, "login_url": server.origin + "/login",
                      "config_path": str(config_path), "results_url": server.origin + "/results"}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
