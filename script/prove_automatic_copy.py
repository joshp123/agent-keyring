#!/usr/bin/env python3
# Written by AI on 2026.11.01 by model gpt-6.1-sol.
"""Real relay + CLI + headless Chrome; short-lived dummy MacBook sender only.
Runs with isolated state and a loopback website. An optional copied app stays
closed; no production service or vault is accessed.
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
from test_login_server import LoginServer, private_json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--relay', type=Path, required=True)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--sender', type=Path, required=True)
parser.add_argument('--listen', default='127.0.0.1:0')
parser.add_argument('--tailscale', default='/run/current-system/sw/bin/tailscale')
parser.add_argument('--application', type=Path, help='Mini-only: copy this real app into the proof directory and prove enrolment with it present; never launch it')
parser.add_argument('--local-fixture', type=Path, help='Dummy local authority for the app-installed proof')
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix='ak-copy-', dir='/tmp'))
env = dict(os.environ, AGENT_KEYRING_STATE_DIR=str(root / 'receiver'), HOME=str(root / 'h'))
env.pop('AGENT_KEYRING_SOCKET', None)
env.pop('AGENT_KEYRING_RELAY', None)
server = LoginServer(0)
server.fixture.update(username='dummy@example.com', password='keyring-r8-dummy-password')
server.totp_secret = b'12345678901234567890'
threading.Thread(target=server.serve_forever, daemon=True).start()
relay = chrome = browser = None
local = application = bundled_cli = None
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

def restart_relay():
    global address
    relay.kill()
    relay.wait(timeout=10)
    if bundled_cli:
        for executable in (args.cli.resolve(), bundled_cli):
            refused = run([str(executable), 'find', '127.0.0.1'], expected=1)
            assert address.encode() in refused.stderr, 'An unavailable relay fell back to the local authority'
        print('PASS selected relay unavailable: standalone and bundled helpers refuse; local app and socket remain present')
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
    if args.application:
        assert args.local_fixture, '--application needs --local-fixture'
        assert os.uname().nodename == 'mac-mini', 'App-installed proof is permitted only on the mini'
        assert not Path('/Applications/AgentKeyring.app').exists(), 'Leave the real installed app untouched; use an isolated mini without it'
        application = root / 'AgentKeyring.app'
        subprocess.run(['/usr/bin/ditto', str(args.application), str(application)], check=True)
        bundled_cli = application / 'Contents/Helpers/agent-keyring'
        assert bundled_cli.is_file(), 'Supply a built, signed app containing the current CLI'
        identity = subprocess.check_output(['/usr/bin/plutil', '-extract', 'CFBundleIdentifier', 'raw', '-o', '-', str(application / 'Contents/Info.plist')], text=True).strip()
        local_socket = root / 'h/Library/Containers' / identity / 'Data/agent.sock'
        local_socket.parent.mkdir(parents=True)
        fixture = root / 'local-fixture.json'
        private_json(fixture, server.fixture)
        local = subprocess.Popen([str(args.local_fixture.resolve()), '--socket', str(local_socket), '--fixture', str(fixture), '--state', str(root / 'local-authority')], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        wait_for(local_socket.exists)
        refused = run([str(args.cli.resolve()), 'find', '127.0.0.1'], expected=1)
        assert b'No authority is selected' in refused.stderr, 'A stray socket selected an authority'
        local_index = run([str(bundled_cli), 'find', '127.0.0.1']).stdout
        assert b'fixture-login' not in local_index
        assert run([str(args.cli.resolve()), 'find', '127.0.0.1']).stdout == local_index
        print('PASS local selection recorded: bundled helper and standalone package use the same app; a socket alone selects nothing')
        # Mirror the dangling app links left by an uninstall, in this proof's
        # private home only. The packaged command repairs all three.
        for destination, target in {
            '.local/bin/agent-keyring': '/Applications/AgentKeyring.app/Contents/Helpers/agent-keyring',
            '.codex/skills/agent-keyring': '/Applications/AgentKeyring.app/Contents/Resources/AgentTools/AgentSkill/agent-keyring',
            '.claude/skills/agent-keyring': '/Applications/AgentKeyring.app/Contents/Resources/AgentTools/AgentSkill/agent-keyring',
        }.items():
            link = root / 'h' / destination
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
        cli('install')
        assert (root / 'h/.local/bin/agent-keyring').resolve() == args.cli.resolve()
        skill = cli('skill')
        for harness in ('.codex', '.claude'):
            assert (root / 'h' / harness / 'skills/agent-keyring/SKILL.md').read_text().strip() == skill
        print('PASS standalone package: bundled skill prints; install repairs dangling command and both skill links in an isolated home')
    start_relay()
    sender('setup')
    enrol = subprocess.Popen([str(args.cli.resolve()), 'enrol', '--name', 'Dummy offline-copy receiver',
                              '--relay', address], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sender('enrol')
    stdout, stderr = enrol.communicate(timeout=30)
    assert enrol.returncode == 0, stderr.decode()
    assert not stdout and re.search(rb'(?:[0-9A-F]{4} ){7}[0-9A-F]{4}', stderr)
    if bundled_cli:
        for executable in (args.cli.resolve(), bundled_cli):
            assert b'fixture-login' in run([str(executable), 'find', '127.0.0.1']).stdout
        print('PASS enrolment with app installed: both entry points use the recorded relay without connection overrides; local authority still serves its own login')
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
    if local:
        local.terminate()
        local.wait(timeout=10)
    if application:
        for extension in (application / 'Contents/PlugIns').glob('*.appex'):
            subprocess.run(['/usr/bin/pluginkit', '-r', str(extension)], capture_output=True)
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(application)], capture_output=True)
        registered = subprocess.run(['/usr/bin/pluginkit', '-m', '-A', '-D', '-v'], capture_output=True, text=True)
        assert str(application) not in registered.stdout, 'The proof left its credential extension registered'
        print('PASS cleanup: copied app never launched; its extension and LaunchServices registration are absent')
    server.shutdown()
    log.close()
