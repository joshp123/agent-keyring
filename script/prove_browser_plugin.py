#!/usr/bin/env python3
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import uuid

browser, cli = sys.argv[1], str(Path(sys.argv[2]).resolve())
example_password = b"example-password"


def assert_no_password(contents, location):
    if example_password in contents:
        raise AssertionError("Example password found in " + location)


def check_session_state(directory):
    files = [path for path in directory.rglob("*") if path.is_file()]
    for path in files:
        assert_no_password(path.read_bytes(), "session state directory")
    return len(files)

class SignInPage(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def page(self, name, status=200):
        document = Path(__file__).with_name(name).read_bytes()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(document)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(document)

    def do_GET(self):
        self.page("browser_plugin_login.html")

    def do_POST(self):
        fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
        succeeded = (fields.get("username") == ["example@example.com"]
                     and fields.get("password") == ["example-password"])
        self.page("browser_plugin_success.html" if succeeded
                  else "browser_plugin_failure.html", 200 if succeeded else 401)

with tempfile.TemporaryDirectory(prefix="agent-keyring-browser-proof-") as directory:
    directory = Path(directory)
    certificate, key = directory / "certificate.pem", directory / "key.pem"
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(certificate), "-days", "1",
                    "-subj", "/CN=example.com"], check=True, capture_output=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SignInPage)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = directory / "agent-browser.json"
    config.write_text(json.dumps({"plugins": [{
        "name": "agent-keyring", "command": cli, "args": ["agent-browser-plugin"],
        "capabilities": ["credential.read"],
    }]}))
    # Chromium remaps the connection port while the page origin stays https://example.com.
    environment = dict(os.environ)
    for name in ("AGENT_BROWSER_PLUGINS", "AGENT_BROWSER_PROVIDER", "AGENT_BROWSER_CDP",
                 "AGENT_BROWSER_PROFILE", "AGENT_BROWSER_STATE", "AGENT_BROWSER_RESTORE",
                 "AGENT_BROWSER_SESSION_NAME", "AGENT_BROWSER_AUTO_CONNECT"):
        environment.pop(name, None)
    session = "keyring-proof-" + uuid.uuid4().hex[:8]
    session_state = Path.home() / ".agent-browser/namespaces" / session / "state"
    (session_state / "sessions").mkdir(parents=True)
    command = [browser, "--config", str(config), "--session", session, "--namespace", session,
               "--headed", "false", "--ignore-https-errors", "--proxy-bypass", "example.com",
               "--args", f"--host-resolver-rules=MAP example.com 127.0.0.1:{server.server_port}"]

    captured_stdout = bytearray()
    captured_stderr = bytearray()

    def run(*arguments, timeout=60):
        try:
            result = subprocess.run(command + list(arguments), env=environment, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as failure:
            captured_stdout.extend(failure.stdout or b"")
            captured_stderr.extend(failure.stderr or b"")
            raise
        captured_stdout.extend(result.stdout)
        captured_stderr.extend(result.stderr)
        assert_no_password(captured_stdout, "captured stdout")
        assert_no_password(captured_stderr, "captured stderr")
        if result.returncode:
            raise RuntimeError("agent-browser " + arguments[0] + " failed")
        return result.stdout.decode().strip()

    try:
        run("plugin", "show", "agent-keyring")
        run("open", "https://example.com/login")
        print("Approve the example.com request with Touch ID now.", flush=True)
        print("agent-browser allows 15 seconds for the plugin; approve promptly.", flush=True)
        run("auth", "login", "example.com", "--credential-provider", "agent-keyring",
            "--item", "example.com example@example.com", "--url", "https://example.com/login", "--no-navigate")
        run("wait", "#result")
        succeeded = run("get", "text", "#result") == "Signed in successfully"
        run("state", "save", str(session_state / "sessions/proof.json"))
        check_session_state(session_state)
        print("PASS: page reports a successful sign-in." if succeeded else "FAIL: page did not report a successful sign-in.")
        if not succeeded:
            sys.exit(1)
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError) as failure:
        print("FAIL: " + str(failure), file=sys.stderr)
        sys.exit(1)
    finally:
        try:
            run("close", timeout=15)
        except (RuntimeError, subprocess.TimeoutExpired, AssertionError) as failure:
            print("FAIL: " + str(failure), file=sys.stderr)
            sys.exit(1)
        finally:
            server.shutdown()
            server.server_close()
            try:
                assert_no_password(captured_stdout, "captured stdout")
                assert_no_password(captured_stderr, "captured stderr")
                checked_files = check_session_state(session_state)
                print(f"PASS: example password absent from captured stdout, stderr and session state ({checked_files} files checked).")
                print("Session state directory: " + str(session_state))
            except (AssertionError, OSError) as failure:
                print("FAIL: " + str(failure), file=sys.stderr)
                sys.exit(1)
