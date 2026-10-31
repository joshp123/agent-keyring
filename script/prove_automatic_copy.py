#!/usr/bin/env python3
# Written by AI on 2026.11.01 by model gpt-6.1-sol.
"""Real relay + CLI + headless Chrome; short-lived dummy MacBook sender only.
Runs with isolated state and a loopback website. No app, service or vault access.
"""
import argparse
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import threading
import time

from prove_cli import Browser, CHROME, wait_for
from test_login_server import LoginServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--relay', type=Path, required=True)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--sender', type=Path, required=True)
parser.add_argument('--listen', default='127.0.0.1:0')
parser.add_argument('--tailscale', default='/run/current-system/sw/bin/tailscale')
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix='keyring-automatic-copy-'))
env = dict(os.environ, AGENT_KEYRING_STATE_DIR=str(root / 'receiver'), HOME=str(root / 'home'))
env.pop('AGENT_KEYRING_SOCKET', None)
server = LoginServer(0)
server.fixture.update(username='dummy@example.com', password='keyring-r8-dummy-password')
server.totp_secret = b'12345678901234567890'
threading.Thread(target=server.serve_forever, daemon=True).start()
relay = chrome = browser = None
log = (root / 'relay.log').open('w+')
address = args.listen
private_markers = (b'keyring-r8-dummy-password', b'keyring-r8-updated-password', b'12345678901234567890')

def run(command, expected=0, timeout=40):
    result = subprocess.run(command, env=env, capture_output=True, timeout=timeout)
    assert all(value not in result.stdout + result.stderr for value in private_markers), 'Dummy secret escaped into ordinary output'
    assert result.returncode == expected, result.stderr.decode()
    return result

def cli(*words, expected=0):
    return run([str(args.cli.resolve()), *words], expected).stdout.decode().strip()

def sender(action):
    result = run([str(args.sender.resolve()), '--mode', 'copy', '--address', address,
                  '--state', str(root / 'sender'), '--action', action, '--site', server.origin])
    print(result.stdout.decode().strip())

def start_relay():
    global relay, address
    log_start = (root / 'relay.log').stat().st_size
    command = [str(args.relay.resolve()), '--listen', address, '--state', str(root / 'relay'), '--tailscale', args.tailscale]
    if address.startswith('127.'):
        command += ['--loopback-test']
    relay = subprocess.Popen(command, stdout=log, stderr=log)
    def started():
        assert relay.poll() is None, (root / 'relay.log').read_text()
        matches = re.findall(r'Agent Keyring relay listening on (\S+)', (root / 'relay.log').read_text()[log_start:])
        return matches[-1] if matches else None
    wait_for(started)
    address = started()
    env['AGENT_KEYRING_RELAY'] = address

def restart_relay():
    global address
    relay.kill()
    relay.wait(timeout=10)
    # Keep the same listening address and the same durable identity/state.
    start_relay()
    time.sleep(.15)

def database(query, values=()):
    with sqlite3.connect(f'file:{root / "relay/relay.sqlite"}?mode=ro', uri=True) as db:
        return db.execute(query, values).fetchall()

def fill(lease, operation):
    browser.navigate(server.origin + '/login')
    browser.wait("!!document.querySelector('#password')")
    before = server.results['password_posts']
    cli('fill', lease, '--browser', endpoint, '--tab', browser.tab, '--username', '#username',
        '--password', '#password', '--submit', '#sign-in', '--operation', operation)
    browser.wait("!!document.querySelector('#verification-code')")
    cli('fill', lease, '--browser', endpoint, '--tab', browser.tab, '--username', '#username',
        '--password', '#password', '--submit', '#sign-in', '--operation', operation)
    assert server.results['password_posts'] == before + 1, 'Receiver retried a completed POST'
    cli('fill', lease, '--browser', endpoint, '--tab', browser.tab, '--code', '#verification-code',
        '--submit', '#verify', '--operation', operation + '-code')
    browser.wait("!!document.querySelector('#authenticated')")

try:
    start_relay()
    sender('setup')
    enrol = subprocess.Popen([str(args.cli.resolve()), 'enrol', '--name', 'Dummy offline-copy receiver',
                              '--relay', address], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sender('enrol')
    stdout, stderr = enrol.communicate(timeout=30)
    assert enrol.returncode == 0, stderr.decode()
    assert not stdout and re.search(rb'(?:[0-9A-F]{4} ){7}[0-9A-F]{4}', stderr)
    profile = root / 'chrome'
    chrome = subprocess.Popen([CHROME, '--headless=new', '--remote-debugging-port=0',
        '--user-data-dir=' + str(profile), '--no-first-run', '--no-default-browser-check', 'about:blank'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_for(lambda: (profile / 'DevToolsActivePort').exists())
    endpoint = 'http://127.0.0.1:' + (profile / 'DevToolsActivePort').read_text().splitlines()[0]
    browser = Browser(endpoint, server.origin + '/login')
    lease = cli('lease', 'fixture-login', '--task', 'sender-stopped', '--reason', 'Dummy unattended sign-in')
    before = cli('status', lease)
    assert ': active' in before
    fill(lease, 'first-password')
    print('PASS sender exited: real CLI filled password and TOTP; website authenticated; retry submitted once')
    delivery = database('SELECT decision,bundle FROM leases WHERE id=?', (lease,))
    sender('resend')
    assert database('SELECT decision,bundle FROM leases WHERE id=?', (lease,)) == delivery
    restart_relay()
    assert cli('status', lease) == before
    fill(lease, 'after-restart')
    assert database('SELECT decision,bundle FROM leases WHERE id=?', (lease,)) == delivery
    print('PASS relay restart retained copy, keys, exact sealed delivery and original lease deadline')
    sender('update')
    server.fixture['password'] = 'keyring-r8-updated-password'
    assert cli('status', lease) == before
    fill(lease, 'changed-password')
    print('PASS password-only update reached the next fill with sender stopped; same lease/deadline; no prompt')
    for action in ('replay', 'conflict', 'outside', 'ask-copy', 'blocked-copy', 'wrong-destination', 'bad-signature'):
        sender(action)
    fill(lease, 'after-refusals')
    sender('ask')
    assert ': revoked' in cli('status', lease)
    assert database('SELECT count(*) FROM automatic_logins') == [(0,)]
    cli('fill', lease, '--browser', endpoint, '--tab', browser.tab, '--password', '#password', '--submit', '#sign-in', '--operation', 'after-ask', expected=1)
    pending = cli('lease', 'fixture-login', '--task', 'now-ask', '--reason', 'Dummy Ask check', '--no-wait')
    assert ': pending' in cli('status', pending)
    cli('release', pending)
    sender('blocked')
    cli('lease', 'fixture-login', '--task', 'now-blocked', '--reason', 'Dummy Blocked check', '--no-wait', expected=1)
    print('PASS acknowledged Automatic-to-Ask removed the copy and revoked delivery; Ask waits; Blocked refuses')
    sender('automatic')
    server.fixture['password'] = 'keyring-r8-dummy-password'
    active = cli('lease', 'fixture-login', '--task', 'replacement', '--reason', 'Dummy replacement check')
    fill(active, 'before-clear')
    sender('clear')
    assert database('SELECT count(*) FROM automatic_logins') == [(0,)]
    cli('fill', active, '--browser', endpoint, '--tab', browser.tab, '--password', '#password', '--submit', '#sign-in', '--operation', 'after-clear', expected=1)
    sender('replay')
    sender('automatic')
    fill(active, 'after-fresh-copy')
    cli('release', active)
    print('PASS empty full replacement clears delivery; replay cannot restore it; fresh higher revision restores service')
    assert server.results['password_rejected'] == server.results['verification_rejected'] == 0
    print('All Automatic copy checks passed. Isolated state:', root)
finally:
    if browser:
        browser.close()
    if chrome:
        chrome.terminate()
        chrome.wait(timeout=10)
    if relay:
        relay.terminate()
        relay.wait(timeout=10)
    server.shutdown()
    log.close()
