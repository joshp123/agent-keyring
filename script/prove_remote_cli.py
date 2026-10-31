#!/usr/bin/env python3
# Written by AI on 2026.10.31 by model gpt-6.1-sol.
"""Use the real CLI over TLS with synthetic deliveries, including CryptoKit.
No Passwords data, human approval, or production relay is involved here.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--cryptokit', type=Path)
parser.add_argument('--browser', action='store_true', help='Mac mini only: exercise signed bundle sites and real Chrome')
parser.add_argument('--interruptions', action='store_true', help='Send Go preemption signals during CLI calls, including file and tab locking')
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix='keyring-remote-cli-'))
state = root / 'receiver'
env = dict(os.environ, AGENT_KEYRING_STATE_DIR=str(state))
env.pop('AGENT_KEYRING_SOCKET', None)
log = (root / 'fixture.log').open('w+')
server = browser = chrome = None
command = [str(args.fixture.resolve()), '--state', str(root / 'relay')]
if args.browser:
    import threading
    import test_login_server
    from prove_cli import Browser, CHROME, wait_for
    server = test_login_server.LoginServer(0)
    server.fixture.update(username='dummy@example.com', password='keyring-r3-dummy-password')
    test_login_server.verification_code = lambda secret, timestamp: '583912'
    threading.Thread(target=server.serve_forever, daemon=True).start()
    command += ['--site', server.origin]
if args.cryptokit:
    command += ['--cryptokit', str(args.cryptokit.resolve())]
fixture = subprocess.Popen(command, stdout=log, stderr=log)

def mode(value):
    (root / 'relay' / 'mode').write_text(value)

def run(*words, code=0, private=False):
    command = [str(args.cli.resolve()), *words]
    if args.interruptions:
        child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 40
        while True:
            try:
                stdout, stderr = child.communicate(timeout=.005)
                result = subprocess.CompletedProcess(command, child.returncode, stdout, stderr)
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    child.kill()
                    child.communicate()
                    raise
                try:
                    child.send_signal(signal.SIGURG)
                except ProcessLookupError:
                    pass
    else:
        result = subprocess.run(command, env=env, capture_output=True, timeout=40)
    if result.returncode != code:
        raise RuntimeError(f'{words[0]} returned {result.returncode}: {result.stderr.decode()}')
    if not private and b'keyring-r3-dummy-password' in result.stdout + result.stderr:
        raise RuntimeError('A dummy credential escaped into ordinary command output')
    return result

try:
    address = None
    for _ in range(100):
        log.flush()
        text = (root / 'fixture.log').read_text()
        match = re.search(r'LISTEN (\S+)', text)
        if match:
            address = match[1]
            break
        if fixture.poll() is not None:
            raise RuntimeError(text)
        time.sleep(.05)
    assert address, 'fixture did not start'
    env['AGENT_KEYRING_RELAY'] = address
    enrol = run('enrol', '--name', 'Dummy receiver', '--relay', address)
    assert enrol.stdout == b''
    compared = re.search(rb'(?:[0-9A-F]{4} ){7}[0-9A-F]{4}', enrol.stderr).group().decode()
    assert 'COMPARE ' + compared in (root / 'fixture.log').read_text()
    assert (state / 'keys.pb').stat().st_mode & 0o777 == 0o600
    print('PASS enrol: locally computed eight-group fingerprint; signed approval; private key storage')
    assert b'dummy' in run('find', 'example.com').stdout
    print('PASS signed login index')
    child = root / 'login.py'
    child.write_text('import pathlib,sys\nvalue=sys.stdin.read()\nassert value=="keyring-r3-dummy-password"\np=pathlib.Path(sys.argv[1]);p.write_text(p.read_text()+"1" if p.exists() else "1")\nprint(value)\n')
    marker = root / 'signed-in'
    lease = run('lease', 'dummy', '--task', 'program', '--reason', 'Dummy program login', '--for', 'program', '--', sys.executable, str(child), str(marker)).stdout.decode().strip()
    assert run('exec', lease, '--field', 'password', '--operation', 'login').stdout == b''
    assert run('exec', lease, '--field', 'password', '--operation', 'login').stdout == b''
    assert marker.read_text() == '1'
    assert run('release', lease).stdout == b''
    print('PASS program sign-in: echo suppressed, cross-process retry did not rerun, explicit release')
    lease = run('lease', 'dummy', '--task', 'agent', '--reason', 'Dummy agent process', '--for', 'agent-process').stdout.decode().strip()
    result = run('read', lease, '--field', 'password', private=True)
    assert result.stdout == b'keyring-r3-dummy-password'
    assert run('read', lease, '--field', 'one-time-code', private=True).stdout == b'583912'
    print('PASS private agent-process password and current code delivery')
    failures = {
        'wrong-recipient': 'different recipient',
        'changed-task': 'saved login, task or program',
        'wrong-lease': 'different lease',
        'expired': 'deadline has expired',
        'unknown-signer': 'unknown approver',
        'tampered-ciphertext': 'ciphertext was changed',
        'bad-enc': 'encapsulated key',
        'bundle-login': 'opened login does not match',
        'bad-chain': 'key chain has an invalid signature',
        'phone-chain': 'required approver role',
        'delivery-chain': 'required approver role',
    }
    for fault, expected in failures.items():
        mode(fault)
        refused = run('read', lease, '--field', 'password', code=1)
        assert refused.stdout == b'' and expected.encode() in refused.stderr, refused.stderr
        print('PASS refused ' + fault)
    if args.browser:
        profile = root / 'chrome'
        chrome = subprocess.Popen([CHROME, '--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + str(profile), '--no-first-run', '--no-default-browser-check', 'about:blank'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: (profile / 'DevToolsActivePort').exists())
        endpoint = 'http://127.0.0.1:' + (profile / 'DevToolsActivePort').read_text().splitlines()[0]
        browser = Browser(endpoint, server.origin + '/login')
        browser.wait("!!document.querySelector('#password')")
        mode('')
        web = run('lease', 'dummy', '--task', 'browser', '--reason', 'Dummy remote browser login').stdout.decode().strip()
        fill = ['fill', web, '--browser', endpoint, '--tab', browser.tab]
        password = [*fill, '--username', '#username', '--password', '#password', '--submit', '#sign-in']
        mode('wrong-site')
        refused = run(*password, '--operation', 'wrong-site', code=1)
        assert b'saved destinations' in refused.stderr and server.results['password_posts'] == 0
        mode('')
        run(*password, '--operation', 'password')
        browser.wait("!!document.querySelector('#verification-code')")
        run(*password, '--operation', 'password')
        assert server.results['password_posts'] == 1
        run(*fill, '--code', '#verification-code', '--submit', '#verify', '--operation', 'code')
        browser.wait("!!document.querySelector('#authenticated')")
        assert server.results['verification_accepted'] == 1
        browser.navigate(server.origin + '/login')
        browser.wait("!!document.querySelector('#password')")
        browser.evaluate("window.submits=0;document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();window.submits++})")
        run(*password, '--again')
        assert browser.evaluate("window.submits===1 && [...document.querySelectorAll('input')].every(e=>e.value==='')")
        run('release', web)
        print('PASS remote Chrome: signed sites enforced, password then code authenticated, repeat submitted once, SPA inputs cleared')
    for denial in ('denial-human', 'denial-tampered', 'denial-unsigned', 'denial-bundle'):
        mode(denial)
        refused = run('lease', 'dummy', '--task', denial, '--reason', 'Dummy denial', '--request', denial, '--for', 'agent-process', code=1)
        assert b'Unsigned relay instruction' not in refused.stderr and b'Tampered reply' not in refused.stderr
        assert (b'Use the dummy staging login instead.' in refused.stderr) == (denial == 'denial-human')
        status = run('status', denial).stdout
        assert (b'Use the dummy staging login instead.' in status) == (denial == 'denial-human')
        assert b'Unsigned relay instruction' not in status and b'Tampered reply' not in status
    print('PASS denial history: show only verified HUMAN reply; hide changed, unsigned and bundle-bearing replies')
    mode('automatic')
    auto = run('lease', 'dummy', '--task', 'automatic', '--reason', 'Dummy Automatic grant', '--for', 'agent-process').stdout.decode().strip()
    assert run('read', auto, '--field', 'password', private=True).stdout == b'keyring-r3-dummy-password'
    print('PASS Automatic signing key with current owner grant and signed enrolment permission')
    mode('rotated')
    assert run('read', lease, '--field', 'password', private=True).stdout == b'keyring-r3-dummy-password'
    print('PASS signed approver key update from pinned predecessor, new process accepts new signer')
    mode('')
    stale = run('read', lease, '--field', 'password', code=1)
    assert stale.stdout == b'' and b'unknown approver' in stale.stderr
    print('PASS removed signer refused after key-set update')
    if args.interruptions:
        print('PASS CLI calls under repeated Go preemption signals, including state locks' + (' and browser tab locks' if args.browser else ''))
    print('All remote CLI checks passed' + (' with CryptoKit signatures and HPKE.' if args.cryptokit else '.'))
finally:
    if browser:
        browser.close()
    if chrome:
        chrome.terminate()
        chrome.wait(timeout=10)
    if server:
        server.shutdown()
    fixture.terminate()
    try:
        fixture.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fixture.kill()
        fixture.wait()
    log.close()
    shutil.rmtree(root)
