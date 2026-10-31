#!/usr/bin/env python3
"""Written by AI on 2026.10.31 by model gpt-6.1-sol.
Run complete CLI workflows with a dummy authority and real debug-port Chrome.
Requires built build/cli/agent-keyring and build/cli/lease-fixture. No vault access.
"""
import base64
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

from test_login_server import LoginServer, private_json
from check_login_artifacts import patterns

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "build/cli/agent-keyring"
AUTHORITY = ROOT / "build/cli/lease-fixture"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


class Browser:
    """Small CDP proof driver. It never reads credential values."""
    def __init__(self, endpoint, url):
        request = urllib.request.Request(endpoint + "/json/new?" + url, method="PUT")
        target = json.load(urllib.request.urlopen(request))
        self.tab = target["id"]
        address = urllib.parse.urlsplit(target["webSocketDebuggerUrl"])
        self.connection = socket.create_connection((address.hostname, address.port), timeout=10)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        self.connection.sendall((f"GET {address.path} HTTP/1.1\r\nHost: {address.netloc}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        response = bytearray()
        while not response.endswith(b"\r\n\r\n"):
            response.extend(self.connection.recv(1))
        assert b"101" in response.split(b"\r\n")[0]
        self.sequence = 0

    def take(self, length):
        result = bytearray()
        while len(result) < length:
            block = self.connection.recv(length - len(result))
            if not block:
                raise RuntimeError("debugger closed")
            result.extend(block)
        return bytes(result)

    def call(self, method, params):
        self.sequence += 1
        payload = json.dumps(dict(id=self.sequence, method=method, params=params)).encode()
        mask = secrets.token_bytes(4)
        header = b"\x81" + (bytes([0x80 | len(payload)]) if len(payload) < 126 else b"\xfe" + struct.pack(">H", len(payload)))
        self.connection.sendall(header + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))
        while True:
            header = self.take(2)
            length = header[1] & 127
            if length == 126:
                length = struct.unpack(">H", self.take(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.take(8))[0]
            reply = json.loads(self.take(length))
            if reply.get("id") == self.sequence:
                if "error" in reply:
                    raise RuntimeError("debugger refused proof action")
                return reply["result"]

    def wait_console(self, message):
        while True:
            header = self.take(2)
            length = header[1] & 127
            if length == 126:
                length = struct.unpack(">H", self.take(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.take(8))[0]
            event = json.loads(self.take(length))
            if event.get("method") == "Runtime.consoleAPICalled" and any(arg.get("value") == message for arg in event["params"]["args"]):
                return

    def evaluate(self, expression):
        return self.call("Runtime.evaluate", dict(expression=expression, returnByValue=True))["result"].get("value")

    def wait(self, expression):
        for _ in range(100):
            try:
                if self.evaluate(expression):
                    return
            except RuntimeError:
                pass
            time.sleep(.05)
        raise AssertionError("Browser did not reach the expected page")

    def navigate(self, url):
        self.call("Page.navigate", dict(url=url))
        self.wait("document.readyState === 'complete'")

    def close(self):
        self.call("Page.close", {})
        self.connection.close()


def main():
    directory = Path(tempfile.mkdtemp(prefix="keyring-cli-proof-"))
    print("Proof artifacts:", directory, flush=True)
    state = directory / "authority"
    fixture_socket = directory / "authority.sock"
    server = LoginServer(0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = directory / "fixture.json"
    private_json(config, server.fixture)
    environment = dict(os.environ, AGENT_KEYRING_SOCKET=str(fixture_socket), AGENT_KEYRING_STATE_DIR=str(directory / "receiver"), HOME=str(directory / "home"))
    processes = []
    browsers = []
    transcript = bytearray()

    def start_authority():
        fixture_socket.unlink(missing_ok=True)  # ephemeral socket, not work product
        process = subprocess.Popen([AUTHORITY, "--socket", fixture_socket, "--fixture", config, "--state", state], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        processes.append(process)
        wait_for(lambda: fixture_socket.exists())
        return process

    def run(*args, expected=0, private=False, env=environment, error_contains=None):
        result = subprocess.run([CLI, *map(str, args)], env=env, capture_output=True, timeout=30)
        transcript.extend(result.stderr)
        (directory / "cli-transcript.txt").write_bytes(transcript)
        if args[0] == "fill":
            print(result.stderr.decode().strip(), flush=True)
        if not private:
            transcript.extend(result.stdout)
        if result.returncode != expected:
            raise AssertionError(f"{args[0]} exited {result.returncode}, expected {expected}: " + result.stderr.decode())
        if error_contains is not None:
            assert error_contains.encode() in result.stderr, result.stderr.decode()
        assert server.fixture["password"].encode() not in transcript
        return result.stdout.decode().strip()

    def lease(task, *args):
        value = run("lease", "dummy", "--task", task, "--reason", "Prove dummy login", *args)
        assert len(value) == 32 and "\n" not in value
        return value

    try:
        authority = start_authority()
        run("find", "127.0.0.1", private=True)
        run("lease", "dummy", expected=2)
        run("read", "missing", "--field", "unknown", expected=2)
        agent = lease("agent-code", "--for", "agent-process")
        assert lease("agent-code", "--for", "agent-process") == agent
        assert run("read", agent, "--field", "password", private=True) == server.fixture["password"]
        run("read", agent, "--field", "one-time-code", private=True)
        run("status", agent, "--wait")
        run("release", agent)
        run("read", agent, "--field", "password", expected=1)
        print("PASS: private agent-process delivery, task rejoin and release.")

        child = directory / "child.py"
        child.write_text("import json,pathlib,sys\nf=json.load(open(sys.argv[1])); value=sys.stdin.read(); assert value==f['password']; p=pathlib.Path(sys.argv[2]); p.write_text(p.read_text()+'x' if p.exists() else 'x'); print(value); print(value,file=sys.stderr); sys.exit(7)\n")
        count = directory / "child-runs"
        program = lease("program", "--for", "program", "--", sys.executable, child, config, count)
        assert run("exec", program, "--field", "password", expected=7) == ""
        run("exec", program, "--field", "password", expected=7)
        assert count.read_text() == "x"
        run("exec", program, "--field", "password", "--operation", "bound-step", expected=7)
        run("exec", program, "--field", "username", "--operation", "bound-step", expected=1, error_contains="different action")
        assert count.read_text() == "xx"
        run("exec", program, "--field", "password", "--again", expected=7)
        assert count.read_text() == "xxx"
        run("release", program)
        print("PASS: bound program stdin, echoed output suppressed, retained exit status, deliberate repeat.")

        # Kill the receiver while the approved program is still running. Its
        # Started receipt must survive and block a new process from rerunning it.
        waiting_child = directory / "waiting-child.py"
        waiting_child.write_text("import pathlib,sys,time\nvalue=sys.stdin.read(); p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text()+'x' if p.exists() else 'x');time.sleep(3)\n")
        waiting_count = directory / "waiting-child-runs"
        waiting_lease = lease("interrupted-program", "--for", "program", "--", sys.executable, waiting_child, waiting_count)
        waiting = subprocess.Popen([CLI, "exec", waiting_lease, "--field", "password"], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(waiting)
        wait_for(waiting_count.exists)
        waiting.kill(); waiting.communicate(timeout=5)
        authority.terminate(); authority.wait(); authority = start_authority()
        run("exec", waiting_lease, "--field", "password", expected=1, error_contains="may have started")
        assert waiting_count.read_text() == "x"
        run("release", waiting_lease)
        print("PASS: receiver killed during program; a new process reports uncertainty without starting it again.")

        profile = directory / "chrome"
        chrome = subprocess.Popen([CHROME, "--headless=new", "--remote-debugging-port=0", "--user-data-dir=" + str(profile), "--no-first-run", "--no-default-browser-check", "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        processes.append(chrome)
        wait_for(lambda: (profile / "DevToolsActivePort").exists())
        port = (profile / "DevToolsActivePort").read_text().splitlines()[0]
        endpoint = "http://127.0.0.1:" + port
        browser = Browser(endpoint, server.origin + "/login")
        browsers.append(browser)
        browser.wait("!!document.querySelector('#password')")
        browser_lease = lease("browser")
        fill = ["fill", browser_lease, "--browser", endpoint, "--tab", browser.tab]
        first = [*fill, "--username", "#username", "--password", "#password", "--submit", "#sign-in"]
        # The receiver remembers its own outcome across navigation and an
        # authority restart. No browser attempt is stored at the authority.
        run(*first)
        browser.wait("!!document.querySelector('#verification-code')")
        authority.terminate(); authority.wait(); start_authority()
        run(*first)
        assert server.results["password_posts"] == 1
        run(*fill, "--code", "#verification-code", "--submit", "#verify", "--operation", "code-step")
        run(*fill, "--code", "#missing-after-navigation", "--submit", "#verify", "--operation", "code-step", expected=1, error_contains="different action")
        browser.wait("!!document.querySelector('#authenticated')")
        assert server.results["verification_accepted"] == 1
        assert not server.results["unrelated_field_received_text"]
        assert not server.results["password_present_in_otp_form"]
        print("PASS: two-step Chrome login; receiver receipt survives navigation and authority restart.")

        # Interrupt the CLI during a real click. The browser completes its
        # submit, but the receiver cannot save an outcome. Its next process
        # must report Uncertain before inspecting the now-different page.
        browser.navigate(server.origin + "/login")
        browser.wait("!!document.querySelector('#password')")
        browser.call("Runtime.enable", {})
        browser.evaluate("document.querySelector('form').addEventListener('submit',()=>{console.log('proof-submit-started'); const until=Date.now()+2000;while(Date.now()<until){}})")
        interrupted_lease = lease("interrupted-browser")
        interrupted_fill = ["fill", interrupted_lease, *first[2:]]
        before_posts = server.results["password_posts"]
        interrupted = subprocess.Popen([CLI, *interrupted_fill], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(interrupted)
        browser.wait_console("proof-submit-started")
        interrupted.kill(); interrupted.communicate(timeout=5)
        browser.wait("!!document.querySelector('#verification-code')")
        run(*interrupted_fill, expected=1, error_contains="earlier fill is uncertain")
        assert server.results["password_posts"] == before_posts + 1
        run("release", interrupted_lease)
        print("PASS: receiver killed during browser submit; retry is uncertain and the site receives one POST.")

        # An SPA leaves its original controls alive after submit. Prove actual
        # field clearing, including the password, without returning their values.
        browser.navigate(server.origin + "/login")
        browser.wait("!!document.querySelector('#password')")
        browser.evaluate("window.submits=0; document.querySelector('form').addEventListener('submit',e=>{e.preventDefault(); window.submits++})")
        run(*first, "--again")
        assert browser.evaluate("window.submits === 1 && [...document.querySelectorAll('input')].every(e=>e.value==='')")
        run(*first, "--again")
        assert browser.evaluate("window.submits === 2 && [...document.querySelectorAll('input')].every(e=>e.value==='')")
        invalid = [*fill, "--password", "#unrelated", "--submit", "#sign-in", "--again"]
        run(*invalid, expected=1)
        assert browser.evaluate("document.querySelector('#unrelated').value === ''")
        # Two independent CLI processes race on the same fresh step. The tab
        # lock plus the receiver's atomic receipt must permit only one submit.
        concurrent_lease = lease("concurrent-fill")
        concurrent = [str(CLI), *first[0:1], concurrent_lease, *first[2:]]
        before = browser.evaluate("window.submits")
        attempts = [subprocess.Popen(concurrent, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        for attempt in attempts:
            stdout, stderr = attempt.communicate(timeout=30)
            assert attempt.returncode == 0 and not stdout
            transcript.extend(stderr)
        assert browser.evaluate("window.submits") == before + 1
        run("release", concurrent_lease)
        # A loopback HTTP server claiming to be CDP must fail ownership checks.
        run("fill", browser_lease, "--browser", server.origin, "--tab", browser.tab,
            "--password", "#password", "--submit", "#sign-in", "--again", expected=1)
        run("release", browser_lease)
        print("PASS: SPA submission clears residual inputs; inappropriate field refused.")

        install_home = directory / "install-home"
        install_environment = dict(environment, HOME=str(install_home))
        run("install", env=install_environment)
        skill = install_home / ".codex/skills/agent-keyring/SKILL.md"
        assert skill.read_bytes() == (ROOT / "AgentSkill/agent-keyring/SKILL.md").read_bytes()
        run("install", env=install_environment)
        print("PASS: installed command and both skills link to the same build/resources.")
        (directory / "cli-transcript.txt").write_bytes(transcript)
        assert not any(secret in transcript for secret in patterns(server.fixture))
        print("PASS: concurrent fills submit once; fake endpoint refused; receiver transcript has no fixture values or common encodings.")
        print("Proof artifacts:", directory)
    finally:
        for browser in browsers:
            try:
                browser.close()
            except Exception:
                pass
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
        server.shutdown()


def wait_for(predicate):
    for _ in range(200):
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError("Process did not become ready")


if __name__ == "__main__":
    main()
