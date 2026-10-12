#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_BROWSER="${AGENT_BROWSER:-$HOME/.local/state/nix/profiles/ai/bin/agent-browser}"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [agent-keyring-executable]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  CLI_PATH="$1"
else
  CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache" /usr/bin/xcrun swift build \
    --package-path "$ROOT_DIR/AgentKeyringPackage" --cache-path "$ROOT_DIR/.build/swiftpm-cache" \
    --scratch-path "$ROOT_DIR/.build/scratch" --product agent-keyring
  CLI_PATH="$ROOT_DIR/.build/scratch/debug/agent-keyring"
fi

# This server accepts only the app's public example login. No imported login is requested.
python3 - "$AGENT_BROWSER" "$CLI_PATH" <<'PY'
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

class SignInPage(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def page(self, body, status=200):
        document = ("<!doctype html><html><meta charset='utf-8'><title>Example sign in</title>"
                    "<body>" + body + "</body></html>").encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(document)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(document)

    def do_GET(self):
        self.page("""<h1>Example sign in</h1><form method='post' action='/login'>
            <label>Username <input name='username' autocomplete='username' required></label>
            <label>Password <input name='password' type='password' autocomplete='current-password' required></label>
            <button type='submit'>Sign in</button></form>""")

    def do_POST(self):
        fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode())
        succeeded = (fields.get("username") == ["example@example.com"]
                     and fields.get("password") == ["example-password"])
        self.page("<h1 id='result'>Signed in successfully</h1>" if succeeded
                  else "<h1 id='result'>Sign in failed</h1>", 200 if succeeded else 401)

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
    command = [browser, "--config", str(config), "--session", "keyring-proof-" + uuid.uuid4().hex,
               "--headed", "false", "--ignore-https-errors", "--proxy-bypass", "example.com",
               "--args", f"--host-resolver-rules=MAP example.com 127.0.0.1:{server.server_port}"]

    def run(*arguments):
        result = subprocess.run(command + list(arguments), env=environment, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError("agent-browser " + arguments[0] + " failed; no credential output was printed")
        return result.stdout.decode().strip()

    try:
        run("plugin", "show", "agent-keyring")
        run("open", "https://example.com/login")
        print("Approve the example.com username and password requests with Touch ID now.", flush=True)
        print("agent-browser allows 15 seconds for the plugin; approve both prompts promptly.", flush=True)
        run("auth", "login", "example.com", "--credential-provider", "agent-keyring",
            "--item", "example.com example@example.com", "--url", "https://example.com/login", "--no-navigate")
        run("wait", "#result")
        succeeded = run("get", "text", "#result") == "Signed in successfully"
        print("PASS: page reports a successful sign-in." if succeeded else "FAIL: page did not report a successful sign-in.")
        if not succeeded:
            sys.exit(1)
    except (RuntimeError, subprocess.TimeoutExpired):
        print("FAIL: sign-in did not complete. Keep Agent Keyring running with its example login enabled and approve promptly.", file=sys.stderr)
        sys.exit(1)
    finally:
        subprocess.run(command + ["close"], env=environment, capture_output=True, timeout=15)
        server.shutdown()
        server.server_close()
PY
