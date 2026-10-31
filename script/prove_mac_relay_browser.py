#!/usr/bin/env python3
# Written by AI on 2026.10.31 by model gpt-6.1-sol.
"""Mini-only real CLI / Swift approver / production relay / headless Chrome.
The caller keeps the paired dummy approver and relay alive; rule is Automatic.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from prove_cli import Browser, CHROME, wait_for
from test_login_server import LoginServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', required=True)
parser.add_argument('--task', default='mac-remote-browser')
parser.add_argument('--hold-before-fill', type=Path)
args = parser.parse_args()
server = LoginServer(8443, example_login=True)
server.example_login = False
server.totp_secret = b'12345678901234567890'
threading.Thread(target=server.serve_forever, daemon=True).start()
browser = chrome = None

def run(*arguments):
    result = subprocess.run([args.cli, *arguments], capture_output=True, timeout=120)
    assert b'example-password' not in result.stdout + result.stderr
    assert b'12345678901234567890' not in result.stdout + result.stderr
    assert result.returncode == 0, result.stderr.decode()
    return result.stdout.decode().strip()

try:
    directory = Path(tempfile.mkdtemp(prefix="keyring-mac-r3-browser-"))
    profile = Path(directory) / 'chrome'
    chrome = subprocess.Popen([CHROME, '--headless=new', '--remote-debugging-port=0',
        '--user-data-dir=' + str(profile), '--no-first-run', '--no-default-browser-check', 'about:blank'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_for(lambda: (profile / 'DevToolsActivePort').exists())
    endpoint = 'http://127.0.0.1:' + (profile / 'DevToolsActivePort').read_text().splitlines()[0]
    browser = Browser(endpoint, server.origin + '/login')
    browser.wait("!!document.querySelector('#password')")
    lease = run('lease', '00000000-0000-0000-0000-000000000301', '--task', args.task, '--reason', 'Dummy two-step sign-in')
    if args.hold_before_fill:
        deadline = time.monotonic() + 120
        while args.hold_before_fill.exists():
            assert time.monotonic() < deadline, 'Proof did not release browser fill'
            time.sleep(.05)
    fill = ['fill', lease, '--browser', endpoint, '--tab', browser.tab]
    password = [*fill, '--username', '#username', '--password', '#password', '--submit', '#sign-in', '--operation', 'password']
    run(*password)
    browser.wait("!!document.querySelector('#verification-code')")
    run(*password)
    assert server.results['password_posts'] == 1
    run(*fill, '--code', '#verification-code', '--submit', '#verify', '--operation', 'code')
    browser.wait("!!document.querySelector('#authenticated')")
    assert server.results['verification_accepted'] == 1
    run('release', lease)
    print('PASS actual CLI, Swift approver and real relay: Chrome password then TOTP sign-in; retry submitted once')
finally:
    if browser:
        browser.close()
    if chrome:
        chrome.terminate()
        chrome.wait(timeout=10)
    server.shutdown()
    subprocess.run(["trash", str(directory)], check=True, timeout=10)
