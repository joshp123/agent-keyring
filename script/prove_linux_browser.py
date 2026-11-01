#!/usr/bin/env python3
"""Written by AI on 2026.11.01 by model gpt-6.1-sol.
Real agents, desktop Chromium, native messaging and the production tailnet relay.
Use only disposable profiles, dummy credentials and isolated installer paths.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import threading
import time

from check_login_artifacts import patterns
from test_login_server import LoginServer, private_json


def wait_for(predicate, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for proof setup')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--relay', type=Path, required=True)
parser.add_argument('--approver', type=Path, required=True)
parser.add_argument('--browser', type=Path, required=True)
parser.add_argument('--extension', type=Path, required=True)
parser.add_argument('--xvfb', type=Path, required=True)
parser.add_argument('--codex', type=Path)
parser.add_argument('--codex-full-access', action='store_true',
                    help='Use an explicitly authorised per-run Codex full-access setting; leave its saved configuration unchanged')
parser.add_argument('--claude', type=Path)
parser.add_argument('--state', type=Path)
args = parser.parse_args()
assert args.codex or args.claude, 'Choose at least one authenticated agent'
root = args.state or Path(tempfile.mkdtemp(prefix='ak-linux-browser-'))
root.mkdir(mode=0o700, parents=True, exist_ok=True)
print('Private proof artifacts:', root, flush=True)
cli = str(args.cli.resolve())
extension = args.extension.resolve()
processes = []
output = bytearray()
env = dict(os.environ)
for key in ('AGENT_KEYRING_SOCKET', 'AGENT_KEYRING_RELAY', 'AGENT_KEYRING_STATE_DIR'):
    env.pop(key, None)
env.update(XDG_CONFIG_HOME=str(root / 'config'), XDG_STATE_HOME=str(root / 'state'),
           XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
           PATH=str(args.cli.resolve().parent) + ':' + env['PATH'])
Path(env['XDG_RUNTIME_DIR']).mkdir(mode=0o700)
server = LoginServer(0)
server.login_style = 'async-disabled-formless'
threading.Thread(target=server.serve_forever, daemon=True).start()
fixture = root / 'dummy.json'
private_json(fixture, server.fixture)
artifacts = [args.cli, args.relay, args.approver, *[extension / name for name in ('manifest.json', 'background.js', 'page.js')]]
(root / 'artifacts.json').write_text(json.dumps({str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in artifacts}, indent=2))


def start(command, log, environment=env, **kwargs):
    with (root / log).open('ab') as stream:
        process = subprocess.Popen(list(map(str, command)), env=environment, stdout=stream,
                                   stderr=stream, start_new_session=True, **kwargs)
    processes.append(process)
    return process


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def run(*words, environment=env):
    result = subprocess.run([cli, *map(str, words)], env=environment, capture_output=True, timeout=60)
    output.extend(result.stdout + result.stderr)
    (root / 'cli-output.txt').write_bytes(output)
    assert result.returncode == 0, result.stderr.decode()
    assert not any(secret in output for secret in patterns(dict(server.fixture, username='')))
    return result.stdout.decode()


def inventory():
    result = subprocess.run([cli, 'tabs'], env=env, capture_output=True, timeout=20)
    return result.stdout.decode() if result.returncode == 0 else ''


def verify_install(home, config):
    install_env = dict(env, HOME=str(home))
    install_env.pop('XDG_CONFIG_HOME', None)
    if config is not None:
        install_env['XDG_CONFIG_HOME'] = str(config)
    run('install', environment=install_env)
    base = config or home / '.config'
    for browser in ('google-chrome', 'google-chrome-for-testing', 'chromium', 'BraveSoftware/Brave-Browser', 'microsoft-edge'):
        path = base / browser / 'NativeMessagingHosts/com.agentkeyring.browser.json'
        manifest = json.loads(path.read_text())
        assert manifest['path'] == cli and manifest['type'] == 'stdio'
        assert manifest['allowed_origins'] == ['chrome-extension://mkdkcfdlllhmbiopfomejjhnfhfmphlk/']
        assert path.stat().st_mode & 0o777 == 0o600
    for path in (home / '.local/bin/agent-keyring', home / '.codex/skills/agent-keyring', home / '.claude/skills/agent-keyring'):
        assert path.is_symlink() and path.exists()


try:
    verify_install(root / 'default-home', None)
    verify_install(root / 'xdg-home', Path(env['XDG_CONFIG_HOME']))
    print('PASS Linux install: default and XDG browser manifests, exact host/extension identity, command and both skill links', flush=True)
    address = subprocess.check_output(['tailscale', 'ip', '-4'], text=True).strip()
    with socket.socket() as listener:
        listener.bind((address, 0))
        relay_address = f'{address}:{listener.getsockname()[1]}'
    relay = start([args.relay, '--listen', relay_address, '--state', root / 'relay'], 'relay.log')
    wait_for(lambda: 'listening on' in (root / 'relay.log').read_text())
    approver = start([args.approver, '--mode', 'approver', '--address', relay_address,
                      '--state', root / 'approver', '--browser-fixture', fixture], 'approver.log')
    wait_for(lambda: 'Fixture approver ready.' in (root / 'approver.log').read_text())
    run('enrol', '--name', 'Dummy Linux desktop', '--relay', relay_address)
    assert 'Fixture machine approved:' in (root / 'approver.log').read_text()
    assert not any(key.startswith('AGENT_KEYRING_') for key in env)
    print('PASS real relay: Tailscale-bound TLS, owner pairing and signed Linux enrolment; helper selects saved relay without an authority override', flush=True)

    display_path = root / 'display'
    with display_path.open('wb') as display:
        xvfb = start([args.xvfb, '-displayfd', display.fileno(), '-screen', '0', '1280x900x24',
                      '-nolisten', 'tcp', '-noreset'], 'xvfb.log', pass_fds=(display.fileno(),))
    wait_for(lambda: display_path.read_text().strip())
    env['DISPLAY'] = ':' + display_path.read_text().strip()
    browser_home = root / 'browser-home'
    browser_home.mkdir(mode=0o700)
    browser_env = dict(env, HOME=str(browser_home))
    results = []
    for name, executable in [('codex', args.codex), ('claude', args.claude)]:
        if executable is None:
            continue
        task = root / name
        task.mkdir(mode=0o700)
        # Use Chromium's normal Linux NativeMessagingHosts path registered by
        # install, in an isolated XDG config root. No --browser-profile shortcut.
        profile = Path(env['XDG_CONFIG_HOME']) / 'chromium'
        url = server.origin + '/login?job=' + name
        command = [args.browser, '--user-data-dir=' + str(profile), '--profile-directory=' + name, '--no-first-run',
                   '--no-default-browser-check', '--disable-sync', '--disable-background-networking',
                   '--password-store=basic', '--load-extension=' + str(extension), url]
        (task / 'browser-command.json').write_text(json.dumps(list(map(str, command)), indent=2))
        browser = start(command, name + '/browser.log', environment=browser_env)
        wait_for(lambda: url in inventory())
        assert not (profile / 'DevToolsActivePort').exists()
        command_line = Path(f'/proc/{browser.pid}/cmdline').read_bytes()
        assert b'--headless' not in command_line and b'--remote-debugging' not in command_line
        before = dict(server.results)
        approvals_before = (root / 'approver.log').read_text().count('Fixture lease approved:')
        prompt = run('skill') + '\n\nTask: Sign in to the dummy website\n' + (
            f'Sign in to {url} using its saved login, and check that retrying a completed sign-in step does not submit twice. '
            'Report whether you signed in. Only a shell is available. Your desktop browser tab is already open; leave other apps and profiles alone. '
            'Leave temporary files for the proof runner to clean up.\n')
        (task / 'prompt.txt').write_text(prompt)
        if name == 'codex':
            agent_command = [executable, 'exec', '--json', '--skip-git-repo-check', '-C', task, '-o', task / 'answer.txt', '-']
            if args.codex_full_access:
                agent_command[2:2] = ['-c', 'sandbox_mode="danger-full-access"']
        else:
            agent_command = [executable, '-p', '--verbose', '--output-format', 'stream-json', '--allowedTools', 'Bash,Read']
        (task / 'agent-command.json').write_text(json.dumps(list(map(str, agent_command)), indent=2))
        with (task / 'events.jsonl').open('wb') as events:
            agent = subprocess.Popen(list(map(str, agent_command)), stdin=subprocess.PIPE, stdout=events,
                                     stderr=subprocess.STDOUT, cwd=task, env=env, start_new_session=True)
            processes.append(agent)
            agent.communicate(prompt.encode(), timeout=600)
        transcript = (task / 'events.jsonl').read_bytes()
        assert agent.returncode == 0, 'Agent did not complete; inspect its private transcript'
        assert not any(secret in transcript for secret in patterns(dict(server.fixture, username='')))
        assert all(('agent-keyring ' + word).encode() in transcript for word in ('tabs', 'fields', 'fill', 'release'))
        assert b'already submitted' in transcript, 'Agent did not verify completed-step retry'
        assert not re.search(rb'Runtime\.evaluate|DevToolsActivePort|/json/new|websocket', transcript, re.I)
        assert '/account' in inventory()
        delta = {key: server.results[key] - before[key] for key in ('password_posts', 'password_accepted', 'verification_posts', 'verification_accepted', 'authenticated_visits')}
        approvals = (root / 'approver.log').read_text().count('Fixture lease approved:') - approvals_before
        assert delta['password_posts'] == delta['password_accepted'] == delta['verification_posts'] == delta['verification_accepted'] == approvals == 1, delta
        assert delta['authenticated_visits'] > 0
        results.append(dict(agent=name, approvals=approvals, counts=delta, desktop=True, debugging_port=False, secrets_in_transcript=False))
        (root / 'results.json').write_text(json.dumps(results, indent=2))
        print(f'PASS {name}: desktop Chromium, tabs/fields/fill, one real-relay approval, password + TOTP authenticated, retry adds no POST, no secret output', flush=True)
        stop(browser)
        # A terminated native host may leave its socket. The ordinary tabs
        # command removes disconnected profiles, including after a crash.
        inventory()
        wait_for(lambda: not list((root / 'state/agent-keyring/browsers').glob('*.sock')))
    print('All Linux desktop relay checks passed.', flush=True)
finally:
    for process in reversed(processes):
        stop(process)
    server.shutdown()
    (root / 'cleanup.json').write_text(json.dumps({'processes_stopped': all(p.poll() is not None for p in processes)}, indent=2))
