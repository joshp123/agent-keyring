#!/usr/bin/env python3
"""Written by AI on 2026.10.31 by model gpt-6.1-sol.
Use the real Go CLI, Swift authority, and signed headless Chrome on the mini.
The authority is a signed fixture with only synthetic example.com credentials.
Requires the Go lane's prove_cli.py for its CDP proof driver.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from prove_cli import Browser, CHROME, wait_for
from test_login_server import LoginServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authority", required=True, type=Path)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    server = LoginServer(8443, example_login=True)
    server.totp_secret = b"12345678901234567890"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    environment = dict(os.environ, AGENT_KEYRING_SOCKET=str(args.root / "agent.sock"))
    processes = []
    browser = None
    transcript = bytearray()

    def start_authority():
        process = subprocess.Popen([args.authority, args.root, "--with-code"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True)
        processes.append(process)
        assert process.stdout.readline().startswith("Ready:"), "Authority did not start"
        return process

    def run(*arguments):
        result = subprocess.run([args.cli, *arguments], env=environment,
                                capture_output=True, timeout=30)
        transcript.extend(result.stdout)
        transcript.extend(result.stderr)
        assert b"example-password" not in transcript, "Fixture appeared in CLI output"
        assert b"12345678901234567890" not in transcript, "Seed appeared in CLI output"
        assert result.returncode == 0, f"{arguments[0]} failed: {result.stderr.decode()}"
        return result.stdout.decode().strip()

    try:
        authority = start_authority()
        with tempfile.TemporaryDirectory(prefix="keyring-joint-browser-") as directory:
            profile = Path(directory) / "chrome"
            chrome = subprocess.Popen([CHROME, "--headless=new", "--remote-debugging-port=0",
                                       "--user-data-dir=" + str(profile), "--no-first-run",
                                       "--no-default-browser-check", "about:blank"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(chrome)
            wait_for(lambda: (profile / "DevToolsActivePort").exists())
            port = (profile / "DevToolsActivePort").read_text().splitlines()[0]
            endpoint = "http://127.0.0.1:" + port
            browser = Browser(endpoint, server.origin + "/login")
            browser.wait("!!document.querySelector('#password')")
            lease = run("lease", "00000000-0000-0000-0000-000000000301", "--task",
                        "joint-browser-proof", "--reason", "Sign in to the synthetic account")
            fill = ["fill", lease, "--browser", endpoint, "--tab", browser.tab]
            password = [*fill, "--username", "#username", "--password", "#password",
                        "--submit", "#sign-in"]
            run(*password)
            browser.wait("!!document.querySelector('#verification-code')")
            authority.kill()
            authority.wait()
            start_authority()
            run(*password)
            assert server.results["password_posts"] == 1, "Retry submitted twice"
            run(*fill, "--code", "#verification-code", "--submit", "#verify")
            browser.wait("!!document.querySelector('#authenticated')")
            assert server.results["verification_accepted"] == 1
            assert not server.results["unrelated_field_received_text"]
            assert not server.results["password_present_in_otp_form"]
            run("release", lease)
            browser.close()
            browser = None
            chrome.terminate()
            chrome.wait(timeout=10)
        print("PASS real Swift authority + Go CLI: password and TOTP login in Chrome, "
              "authority restart after navigation, retry submits once, release")
    finally:
        if browser:
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
                    process.kill()
                    process.wait()
        server.shutdown()


if __name__ == "__main__":
    main()
