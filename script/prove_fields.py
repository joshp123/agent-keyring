#!/usr/bin/env python3
"""Written by AI on 2026.11.01 by model gpt-6.1-sol.
Use the shipped extension, native host and CLI in an isolated headless profile.
CDP is used only by the existing proof driver to arrange and inspect test pages;
no Agent Keyring command receives an endpoint. Agent runs have no debugging port.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time

from check_login_artifacts import patterns
from prove_cli import Browser, CHROME, wait_for
from test_login_server import LoginHandler, LoginServer, private_json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--fixture', type=Path, required=True)
parser.add_argument('--extension', type=Path, default=Path(__file__).resolve().parent.parent / 'BrowserExtension')
parser.add_argument('--browser', default=CHROME)
parser.add_argument('--claude', type=Path)
parser.add_argument('--external-claude', action='store_true', help='Wait for a Claude run launched by its authenticated harness in the printed workspace')
parser.add_argument('--codex', type=Path)
parser.add_argument('--agents-only', action='store_true', help='Run only fresh-agent sign-ins')
parser.add_argument('--directory', type=Path, help='New private proof directory, including an external agent workspace')
args = parser.parse_args()
if args.directory:
    root = args.directory.resolve()
    root.mkdir(mode=0o700, parents=True)
else:
    root = Path(tempfile.mkdtemp(prefix='ak-ext-', dir='/tmp'))
print('Private proof artifacts:', root, flush=True)
server = LoginServer(0)
login_observations = []
original_get = LoginHandler.do_GET
def observe_login(self):
    if self.path == '/frame-proof':
        payload = self.document('Frame scope proof', '<iframe src="' + other_site.origin + '/login"></iframe>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        return
    if self.path.startswith('/login'):
        login_observations.append({'path': self.path, 'pending_cookie_present': bool(self.cookie_value('pending')), 'session_cookie_present': bool(self.cookie_value('session'))})
    original_get(self)
LoginHandler.do_GET = observe_login
threading.Thread(target=server.serve_forever, daemon=True).start()
config = root / 'fixture.json'
private_json(config, server.fixture)
runtime = Path(tempfile.mkdtemp(prefix='ak-ext-state-', dir='/tmp')) if args.directory else root
profile = runtime / 'profile'
socket = runtime / 'authority.sock'
env = dict(os.environ, AGENT_KEYRING_SOCKET=str(socket), AGENT_KEYRING_STATE_DIR=str(runtime / 'receiver'))
cli = str(args.cli.resolve())
artifacts = [args.cli.resolve(), *[args.extension.resolve() / name for name in ('manifest.json', 'background.js', 'page.js')], Path(__file__).resolve().parent.parent / 'AgentSkill/agent-keyring/SKILL.md']
(root / 'artifacts.json').write_text(json.dumps({str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in artifacts}, indent=2))
authority = chrome = browser = None
other_site = None
output = bytearray()
processes = []

def run(*words, code=0):
    result = subprocess.run([cli, *map(str, words)], env=env, capture_output=True, timeout=40)
    output.extend(result.stdout + result.stderr)
    (root / 'cli-output.txt').write_bytes(output)
    assert result.returncode == code, result.stderr.decode()
    assert not any(secret in output for secret in patterns(dict(server.fixture, username='')))
    if words[0] == 'fill':
        assert not result.stdout
    return result.stdout.decode()

def inventory():
    return [re.split(r' {2,}', line.strip()) for line in run('tabs').splitlines()[1:]]

def tab_for(url):
    return next(row[0] for row in inventory() if row[3] == url)

def fields(target):
    for _ in range(100):
        result = subprocess.run([cli, 'fields', '--tab', target], env=env, capture_output=True)
        if result.returncode == 0:
            output.extend(result.stdout + result.stderr)
            return result.stdout.decode()
        time.sleep(.05)
    raise AssertionError('The content script did not become ready: ' + result.stderr.decode())

def control_selectors(target, names):
    rows = [re.split(r' {2,}', line.strip()) for line in fields(target).splitlines()]
    return {name: next(row[1] for row in rows if len(row) > 2 and row[1].endswith('#' + name)) for name in names}

def start_browser(url='about:blank', debugging=True):
    command = [args.browser, '--headless=new', '--no-first-run', '--no-default-browser-check',
               '--disable-sync', '--disable-background-networking', '--use-mock-keychain', '--user-data-dir=' + str(profile),
               '--load-extension=' + str(args.extension.resolve())]
    if debugging:
        command.append('--remote-debugging-port=0')
    with (root / 'chrome.log').open('ab') as log:
        process = subprocess.Popen([*command, url], env=env, stdout=log, stderr=log)
    processes.append(process)
    return process

def stop_browser():
    global chrome, browser
    if browser:
        try:
            browser.connection.close()
        except Exception:
            pass
        browser = None
    chrome.terminate()
    chrome.wait(timeout=15)
    wait_for(lambda: not list((runtime / 'receiver/browsers').glob('*.sock')))

def lease(task):
    return run('lease', 'dummy', '--task', task, '--reason', 'Sign in to the dummy website').strip()

try:
    if not args.agents_only:
        run('fields', '--browser', server.origin, code=2)
        run('fill', 'unused', '--browser', server.origin, '--password', '#password', '--submit', '#sign-in', code=2)
        assert server.results['debugger_requests'] == 0
        run('install', '--browser-profile', profile)
        assert not (root / 'home/.local').exists()
        chrome = start_browser()
        wait_for(lambda: (profile / 'DevToolsActivePort').exists())
        endpoint = 'http://127.0.0.1:' + (profile / 'DevToolsActivePort').read_text().splitlines()[0]
        browser = Browser(endpoint, server.origin + '/login')
        browser.wait("!!document.querySelector('#password')")
        wait_for(lambda: list((runtime / 'receiver/browsers').glob('*.sock')))
        target = tab_for(server.origin + '/login')
        # Inspect with no authority, without changing already populated inputs.
        populated = json.dumps(dict(username=server.fixture['username'], password=server.fixture['password']))
        browser.evaluate("(()=>{const v=" + populated + ";document.querySelector('#username').value=v.username;document.querySelector('#password').value=v.password})()")
        controls = fields(target)
        assert all(s in controls for s in ('#username', '#password', '#sign-in', 'Username', 'current-password'))
        assert browser.evaluate("(()=>{const v=" + populated + ";return document.querySelector('#password').value===v.password})()")
        assert not socket.exists() and server.results['password_posts'] == 0
        print('PASS tabs/fields: extension metadata, no authority, no values or mutation', flush=True)
        authority = subprocess.Popen([str(args.fixture.resolve()), '--socket', str(socket), '--fixture', str(config), '--state', str(root / 'authority')], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        processes.append(authority)
        wait_for(socket.exists)
        reviewed_results = []
        for style in ['async', 'disabled', 'formless', 'async-disabled-formless', 'blur',
                      'async-route-controlled', 'async-swap', 'async-route-swap', 'async-error',
                      'async-early-hash', 'async-early-path', 'async-early-hash-route-controlled',
                      'async-synthetic-pagehide', 'async-synthetic-form', 'async-constructor-formdata',
                      'async-early-detach', 'async-early-detach-route-swap', 'async-reattach',
                      'async-hide', 'async-busy', 'stuck', 'invalid',
                      'shadow', 'shadow-nested', 'slot', 'async-late-route-controlled',
                      'async-late-fieldset-route-controlled', 'async-late-shadow-nested-route-swap']:
            server.login_style = style
            url = server.origin + '/login?style=' + style
            browser.navigate(url)
            browser.wait("location.href === " + json.dumps(url) + " && window.proofReady")
            target = tab_for(url)
            before = dict(server.results)
            reference = lease('review-' + style)
            started = time.monotonic()
            selectors = control_selectors(target, ('username', 'password', 'sign-in'))
            if 'shadow' in style: assert ' >>> ' in selectors['password']
            password_fill = ['fill', reference, '--tab', target, '--username', selectors['username'], '--password', selectors['password'], '--submit', selectors['sign-in']]
            attempt = subprocess.run([cli, *password_fill], env=env, capture_output=True, timeout=40)
            output.extend(attempt.stdout + attempt.stderr)
            blocked = style in ('stuck', 'invalid')
            failed_login = style == 'async-error'
            unconfirmed = 'route' in style or 'swap' in style or failed_login
            expected = 1 if blocked or unconfirmed else 0
            assert attempt.returncode == expected, attempt.stderr.decode()
            assert not attempt.stdout
            if unconfirmed:
                assert (18 if 'late' in style else 9) <= time.monotonic() - started < (24 if 'late' in style else 14)
                assert b'uncertain' in attempt.stderr and b'This step is recorded' in attempt.stderr
                assert b'repeating it will not submit again' in attempt.stderr
                if 'route' in style:
                    assert b'The address changed.' in attempt.stderr
                if 'swap' in style or failed_login:
                    assert b'filled fields were removed or replaced.' in attempt.stderr
                if failed_login:
                    assert b'The page displayed an alert.' in attempt.stderr
            password_posts = server.results['password_posts'] - before['password_posts']
            accepted = server.results['password_accepted'] - before['password_accepted']
            assert password_posts == (0 if blocked else 1)
            assert accepted == (0 if blocked or failed_login else 1)
            if 'route' in style or 'swap' in style or blocked or failed_login:
                time.sleep(1)
                assert browser.evaluate("[...document.querySelectorAll('input'), ...window.proofOldInputs || [], ...window.proofInputs || []].every(e=>e.value==='')")
            run(*password_fill, code=expected)
            assert server.results['password_posts'] == before['password_posts'] + password_posts
            if not blocked and not failed_login:
                assert server.results['password_posts'] == before['password_posts'] + 1
                # The route-only page retains its controls deliberately, to check
                # cleanup. Swap pages install the actual code form in this document.
                if 'controlled' in style:
                    browser.navigate(server.origin + '/verify')
                browser.wait("!!document.querySelector('#verification-code') || !!window.proofInputs?.some(e=>e.id==='verification-code')")
                target = tab_for(url if 'swap' in style and 'route' not in style else server.origin + '/verify')
                selectors = control_selectors(target, ('verification-code', 'verify'))
                code_fill = ['fill', reference, '--tab', target, '--code', selectors['verification-code'], '--submit', selectors['verify']]
                run(*code_fill, code=1 if unconfirmed else 0)
                run(*code_fill, code=1 if unconfirmed else 0)
                if 'controlled' in style:
                    time.sleep(1)
                    assert browser.evaluate("[...document.querySelectorAll('input')].every(e=>e.value==='')")
                    browser.navigate(server.origin + '/account')
                browser.wait("!!document.querySelector('#authenticated')")
                if 'swap' in style:
                    assert browser.evaluate("window.proofOldInputs.every(e=>e.value==='')")
                assert server.results['verification_accepted'] == before['verification_accepted'] + 1
            reviewed_results.append({'style': style, 'exit': attempt.returncode, 'password_posts': password_posts, 'accepted': accepted, 'seconds': round(time.monotonic() - started, 2)})
            print('PASS reviewed page:', reviewed_results[-1], flush=True)
            (root / 'reviewed-pages.json').write_text(json.dumps(reviewed_results, indent=2))
            run('release', reference)
        server.login_style = 'native'
        before_core = dict(server.results)
        leases_before_core = len(list((root / 'authority').glob('lease-*')))
        browser.navigate(server.origin + '/login')
        browser.wait("location.pathname === '/login' && !!document.querySelector('#password')")
        target = tab_for(server.origin + '/login')
        granted = lease('extension-proof')
        other = Browser(endpoint, server.origin + '/login')
        other.wait("!!document.querySelector('#password')")
        ambiguity = subprocess.run([cli, 'fill', granted, '--username', '#username', '--password', '#password', '--submit', '#sign-in'], env=env, capture_output=True)
        output.extend(ambiguity.stdout + ambiguity.stderr)
        assert ambiguity.returncode == 1 and b'More than one tab' in ambiguity.stderr
        assert server.results['password_posts'] == before_core['password_posts']
        first = ['fill', granted, '--tab', target, '--username', '#username', '--password', '#password', '--submit', '#sign-in', '--operation', 'password-step']
        run(*first)
        browser.wait("!!document.querySelector('#verification-code') || !!window.proofInputs?.some(e=>e.id==='verification-code')")
        assert other.evaluate("document.querySelector('#password').value === ''")
        run(*first)
        run(*first[:-2], '--operation', 'password-step')
        conflict = subprocess.run([cli, 'fill', granted, '--tab', target, '--password', '#changed', '--submit', '#sign-in', '--operation', 'password-step'], env=env, capture_output=True)
        output.extend(conflict.stdout + conflict.stderr)
        assert conflict.returncode == 1 and b'different action' in conflict.stderr
        assert server.results['password_posts'] == before_core['password_posts'] + 1
        other.close()
        print('PASS identical tabs: untargeted refusal; targeted tab only; retry submits once; changed explicit key refused', flush=True)
        # Native host and browser both restart. Profile identity and lease persist;
        # the old target is refused and a fresh target completes the same task.
        old = tab_for(server.origin + '/verify')
        old_profile = inventory()[0][2]
        before_restart = len(login_observations)
        stop_browser()
        chrome = start_browser(server.origin + '/login', debugging=False)
        wait_for(lambda: list((runtime / 'receiver/browsers').glob('*.sock')))
        wait_for(lambda: any(row[3] == server.origin + '/login' for row in inventory()))
        assert inventory()[0][2] == old_profile
        assert login_observations[before_restart:] and not login_observations[before_restart]['pending_cookie_present']
        print('PASS restart observation: the new login request has no pending two-factor cookie; the browser lost that website session', flush=True)
        run('fields', '--tab', old, code=1)
        target = tab_for(server.origin + '/login')
        assert '#password' in fields(target)
        run('fill', granted, '--tab', target, '--username', '#username', '--password', '#password', '--submit', '#sign-in')
        wait_for(lambda: any(row[3] == server.origin + '/verify' for row in inventory()))
        target = tab_for(server.origin + '/verify')
        assert target != old and 'one-time-code' in fields(target)
        run('fill', granted, '--tab', target, '--code', '#verification-code', '--submit', '#verify')
        wait_for(lambda: any(row[3] == server.origin + '/account' for row in inventory()))
        assert server.results['password_accepted'] == before_core['password_accepted'] + 2 and server.results['verification_accepted'] == before_core['verification_accepted'] + 1
        assert len(list((root / 'authority').glob('lease-*'))) == leases_before_core + 1
        assert 'No visible inputs or buttons.' in fields(tab_for(server.origin + '/account'))
        run('release', granted)
        print('PASS restart without debugging port: same profile and lease; stale target refused; saved TOTP; authenticated page', flush=True)

        # Retained controls in an SPA are actually cleared. Existing proof driver
        # arranges the page and returns booleans, never field values.
        stop_browser()
        chrome = start_browser()
        wait_for(lambda: list((runtime / 'receiver/browsers').glob('*.sock')))
        endpoint = 'http://127.0.0.1:' + (profile / 'DevToolsActivePort').read_text().splitlines()[0]
        browser = Browser(endpoint, server.origin + '/login')
        browser.wait("!!document.querySelector('#password')")
        target = tab_for(server.origin + '/login')
        browser.evaluate("window.submits=0;document.querySelector('form').addEventListener('submit',e=>{e.preventDefault();window.submits++})")
        spa = lease('retained-controls')
        fill = ['fill', spa, '--tab', target, '--username', '#username', '--password', '#password', '--submit', '#sign-in']
        started = time.monotonic()
        before_output = len(output)
        run(*fill, code=1)
        assert 9 <= time.monotonic() - started < 14
        assert b'The address and filled fields stayed in place.' in output[before_output:]
        assert b'This step is recorded' in output[before_output:]
        assert browser.evaluate("window.submits===1 && [...document.querySelectorAll('input')].every(e=>e.value==='')")
        run(*fill, code=1)
        assert browser.evaluate('window.submits===1')
        run(*fill, '--again', code=1)
        assert browser.evaluate("window.submits===2 && [...document.querySelectorAll('input')].every(e=>e.value==='')")
        run('fill', spa, '--tab', target, '--password', '#unrelated', '--submit', '#sign-in', code=1)
        run('release', spa)
        print('PASS unknown submission: bounded retention; Uncertain; cleared fields; retry suppressed; deliberate repeat; unsuitable field refused', flush=True)

        other_site = LoginServer(0)
        threading.Thread(target=other_site.serve_forever, daemon=True).start()
        browser.navigate(server.origin + '/frame-proof')
        browser.wait("!!document.querySelector('iframe')")
        target = tab_for(server.origin + '/frame-proof')
        def foreign_frame_target():
            return next((line.split()[0] for line in fields(target).splitlines() if '#password' in line and line.split()[0] != target), None)
        wait_for(foreign_frame_target)
        wrong_frame = lease('foreign-frame')
        refused = subprocess.run([cli, 'fill', wrong_frame, '--tab', foreign_frame_target(), '--username', '#username', '--password', '#password', '--submit', '#sign-in'], env=env, capture_output=True)
        output.extend(refused.stdout + refused.stderr)
        assert refused.returncode == 1 and b'outside' in refused.stderr
        assert other_site.results['password_posts'] == 0
        run('release', wrong_frame)
        print('PASS frame scope: a visible foreign frame is identified but receives no fill or submit', flush=True)

        # Kill the receiver mid-submit, not the CLI. Its pending receipt survives.
        browser.navigate(server.origin + '/login')
        browser.wait("!!document.querySelector('#password')")
        browser.call('Runtime.enable', {})
        browser.evaluate("document.querySelector('form').addEventListener('submit',()=>{console.log('proof-submit-started');const until=Date.now()+1500;while(Date.now()<until){}})")
        target = tab_for(server.origin + '/login')
        interrupted = lease('interrupted-extension')
        fill = ['fill', interrupted, '--tab', target, '--username', '#username', '--password', '#password', '--submit', '#sign-in']
        attempt = subprocess.Popen([cli, *fill], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        browser.wait_console('proof-submit-started')
        hosts = subprocess.check_output(['pgrep', '-P', str(chrome.pid), '-f', cli + ' chrome-extension://']).decode().split()
        assert len(hosts) == 1
        os.kill(int(hosts[0]), 9)
        stdout, stderr = attempt.communicate(timeout=10)
        output.extend(stdout + stderr)
        browser.wait("!!document.querySelector('#verification-code') || !!window.proofInputs?.some(e=>e.id==='verification-code')")
        wait_for(lambda: list((runtime / 'receiver/browsers').glob('*.sock')))
        result = subprocess.run([cli, *fill], env=env, capture_output=True)
        output.extend(result.stdout + result.stderr)
        assert result.returncode == 1 and b'may have started' in result.stderr
        run('release', interrupted)
        print('PASS killed helper: pending retry is uncertain and does not submit twice', flush=True)

    else:
        run('install', '--browser-profile', profile)
        authority = subprocess.Popen([str(args.fixture.resolve()), '--socket', str(socket), '--fixture', str(config), '--state', str(root / 'authority')], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        processes.append(authority)
        wait_for(socket.exists)
        chrome = start_browser(debugging=False)
        wait_for(lambda: list((runtime / 'receiver/browsers').glob('*.sock')))
    server.login_style = 'async-late-shadow-nested-route-swap'
    for name, executable in [('claude', args.claude or args.external_claude), ('codex', args.codex)]:
        if not executable:
            continue
        stop_browser()
        chrome = start_browser(server.origin + '/login?job=' + name, debugging=False)
        wait_for(lambda: list((runtime / 'receiver/browsers').glob('*.sock')))
        taskdir = root / name
        taskdir.mkdir()
        bindir = taskdir / 'bin'
        bindir.mkdir()
        (bindir / 'agent-keyring').symlink_to(args.cli.resolve())
        skill = run('skill')
        prompt = skill + '\n\n' + f'Task: Sign in to the dummy website\nSign in to {server.origin}/login?job={name} using its saved login, and check that retrying a completed sign-in step does not submit twice. Report whether you signed in. Only a shell is available. Your browser tab is already open headlessly; leave other apps and profiles alone.\n'
        (taskdir / 'prompt.txt').write_text(prompt)
        agent_env = dict(env, PATH=str(bindir) + ':' + os.environ['PATH'])
        before = dict(server.results)
        leases_before = len(list((root / 'authority').glob('lease-*')))
        if name == 'claude' and args.external_claude:
            setup = {'workspace': str(taskdir), 'prompt': str(taskdir / 'prompt.txt'), 'environment': {key: agent_env[key] for key in ('PATH', 'AGENT_KEYRING_SOCKET', 'AGENT_KEYRING_STATE_DIR')}, 'transcript': str(taskdir / 'events.jsonl'), 'finish_marker': str(taskdir / 'finished')}
            (taskdir / 'setup.json').write_text(json.dumps(setup, indent=2))
            print('External Claude workspace:', taskdir, flush=True)
            deadline = time.monotonic() + 1800
            while not (taskdir / 'finished').exists() and time.monotonic() < deadline:
                time.sleep(.2)
            assert (taskdir / 'finished').exists(), 'External Claude run was not completed'
            result = subprocess.CompletedProcess([], int((taskdir / 'finished').read_text()))
        elif name == 'claude':
            command = [str(executable), '-p', '--verbose', '--output-format', 'stream-json', '--tools', 'Bash,Read', '--allowedTools', 'Bash,Read']
        else:
            command = [str(executable), 'exec', '--json', '--skip-git-repo-check', '-C', str(taskdir), '-o', str(taskdir / 'answer.txt'), '-']
        if not (name == 'claude' and args.external_claude):
            with (taskdir / 'events.jsonl').open('w') as events:
                result = subprocess.run(command, input=prompt, text=True, cwd=taskdir, env=agent_env, stdout=events, stderr=subprocess.STDOUT, timeout=600)
        transcript = (taskdir / 'events.jsonl').read_bytes()
        assert result.returncode == 0, 'Agent did not complete; inspect private transcript'
        observations = login_observations[:]
        assert not any(secret in transcript for secret in patterns(dict(server.fixture, username='')))
        assert server.results['password_accepted'] == before['password_accepted'] + 1
        assert server.results['verification_accepted'] == before['verification_accepted'] + 1
        assert len(list((root / 'authority').glob('lease-*'))) == leases_before + 1
        assert any('/account' in row[3] for row in inventory())
        assert b'agent-keyring tabs' in transcript and b'agent-keyring fields' in transcript
        assert b'This step is recorded; nothing was filled or submitted again' in transcript
        assert server.results['password_rejected'] == before['password_rejected']
        assert server.results['verification_rejected'] == before['verification_rejected']
        assert not re.search(rb'websocket|Runtime\.evaluate|/json/new|DevToolsActivePort', transcript, re.I)
        (taskdir / 'results.json').write_text(json.dumps({'before': before, 'after': server.results, 'login_requests_after_agent_start': observations, 'new_leases': len(list((root / 'authority').glob('lease-*'))) - leases_before}, indent=2))
        print(f'PASS uncoached {name}: shell and bundled skill; one lease and retries; password and saved TOTP; authenticated page; no credential output or browser client code', flush=True)

    (root / 'cli-output.txt').write_bytes(output)
    assert not any(secret in output for secret in patterns(dict(server.fixture, username='')))
    print('PASS output scan: no dummy password, current codes or common encodings', flush=True)
finally:
    (root / 'results.json').write_text(json.dumps({'counts': server.results, 'login_requests': login_observations}, indent=2))
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    server.shutdown()
    if other_site:
        other_site.shutdown()
