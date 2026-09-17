#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/usr/bin/xcrun swift build --package-path "$ROOT_DIR/AgentKeyringPackage" --product agent-keyring-fixture
/usr/bin/xcrun swift build --package-path "$ROOT_DIR/AgentKeyringPackage" --product agent-keyring

# This fixture has its own App Sandbox identity. It is executed directly;
# neither the production app nor LaunchServices is involved.
python3 - "$ROOT_DIR" <<'PY'
import base64
import datetime
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import uuid

root = pathlib.Path(sys.argv[1])
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
proof = root / '.build' / ('credential-retention-' + stamp)
proof.mkdir(parents=True, mode=0o700)
app = proof / 'SandboxDeliveryFixture.app'
macos = app / 'Contents' / 'MacOS'
macos.mkdir(parents=True)
fixture = root / 'AgentKeyringPackage' / '.build' / 'debug' / 'agent-keyring-fixture'
cli = root / 'AgentKeyringPackage' / '.build' / 'debug' / 'agent-keyring'
producer = macos / 'SandboxDeliveryFixture'
shutil.copy2(fixture, producer)
identifier = 'com.agentkeyring.SandboxDeliveryFixture'
with (app / 'Contents' / 'Info.plist').open('wb') as stream:
    plistlib.dump({
        'CFBundleIdentifier': identifier,
        'CFBundleExecutable': 'SandboxDeliveryFixture',
        'CFBundleName': 'Sandbox Delivery Fixture',
        'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1',
        'LSUIElement': True,
    }, stream)
entitlements = proof / 'sandbox.entitlements'
with entitlements.open('wb') as stream:
    plistlib.dump({'com.apple.security.app-sandbox': True}, stream)
subprocess.run([
    '/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime',
    '--entitlements', str(entitlements), str(app),
], check=True, capture_output=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
outside = proof / 'outside-sandbox.txt'
outside.write_text('Synthetic sandbox boundary check only.\n')
probe = subprocess.run([str(producer), '--sandbox-probe', str(outside)], capture_output=True, check=True, timeout=15)
probe_result = json.loads(probe.stdout)
assert probe_result['outside_read_denied'] is True, 'Producer was not confined by App Sandbox'
container = pathlib.Path(probe_result['home'])
assert identifier in container.parts, 'Producer did not receive its own test container'
fixture_data = container / 'credential-retention-proof' / stamp
fixture_data.mkdir(parents=True, mode=0o700)
config_path = fixture_data / 'fixture.json'
audit_path = fixture_data / 'audit.jsonl'
canary = base64.urlsafe_b64encode(os.urandom(32)).decode()
configuration = {
    'origin': 'http://127.0.0.1:59183',
    'username': 'synthetic-sandbox-account',
    'password': canary,
    'totp_secret': base64.b64encode(os.urandom(20)).decode(),
    'policy': 'ask',
    'authorization': 'allow',
}
environment = dict(os.environ,
    AGENT_KEYRING_FIXTURE_HOST=str(producer),
    AGENT_KEYRING_FIXTURE_BRIDGE_ROOT=str(fixture_data),
    AGENT_KEYRING_FIXTURE_CONFIG=str(config_path),
    AGENT_KEYRING_FIXTURE_AUDIT=str(audit_path),
)
results = []
for policy, authorization, approval_count, release_count, error in [
    ('ask', 'allow', 1, 1, None),
    ('allowAutomatically', 'allow', 0, 1, None),
    ('block', 'allow', 0, 0, 'policy_denied'),
    ('ask', 'deny', 1, 0, 'authorization_denied'),
    ('ask', 'expire', 1, 0, 'request_expired'),
]:
    configuration.update(policy=policy, authorization=authorization)
    config_path.write_text(json.dumps(configuration))
    config_path.chmod(0o600)
    before = len(audit_path.read_text().splitlines()) if audit_path.exists() else 0
    process = subprocess.run(
        [str(fixture), 'acquire', 'password', configuration['origin']],
        env=environment, capture_output=True, timeout=15,
    )
    output, errors = process.stdout, process.stderr
    assert canary.encode() not in output + errors + audit_path.read_bytes()
    if error:
        assert process.returncode != 0 and error.encode() in errors and output == b''
    else:
        assert process.returncode == 0 and errors == b''
        reference = str(uuid.UUID(output.decode().strip()))
        assert output.decode().strip().upper() == reference.upper()
        try:
            for _ in range(2):
                read = subprocess.run([str(cli), 'read', reference], capture_output=True, timeout=15)
                assert read.returncode == 0 and read.stdout == canary.encode() and not read.stderr
            broken = subprocess.Popen(
                ['/bin/sh', '-c', 'sleep 0.1; exec "$CLI" read "$REFERENCE"'],
                env=dict(os.environ, CLI=str(cli), REFERENCE=reference),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            broken.stdout.close()
            broken_errors = broken.stderr.read()
            assert broken.wait(timeout=15) != 0 and canary.encode() not in broken_errors
            after_failure = subprocess.run([str(cli), 'read', reference], capture_output=True, timeout=15)
            assert after_failure.returncode == 0 and after_failure.stdout == canary.encode()
        finally:
            cleared = subprocess.run([str(cli), 'clear', reference], capture_output=True, timeout=15)
            assert cleared.returncode == 0 and cleared.stdout == cleared.stderr == b''
        clear_again = subprocess.run([str(cli), 'clear', reference], capture_output=True, timeout=15)
        assert clear_again.returncode == 0 and clear_again.stdout == clear_again.stderr == b''
        after_clear = subprocess.run([str(cli), 'read', reference], capture_output=True, timeout=15)
        assert after_clear.returncode != 0 and after_clear.stdout == b'' and after_clear.stderr
    events = [json.loads(line) for line in audit_path.read_text().splitlines()[before:]]
    assert sum(event['stage'] == 'authorization' for event in events) == approval_count
    assert sum(event['stage'] == 'release' for event in events) == release_count
    assert sum(event['stage'] == 'request' for event in events) == 1
    results.append({
        'policy': policy, 'authorization': authorization,
        'approval_count': approval_count, 'release_count': release_count,
        'exit_code': process.returncode, 'acquire_prints_only_reference_or_empty_on_failure': True,
        'retained_read_and_explicit_clear_verified': error is None,
        'secret_absent_from_diagnostics_and_audit': True,
    })
summary = {
    'passed': True,
    'sandbox_enforced': True,
    'outside_read_denied': True,
    'producer_signature': 'ad-hoc; App Sandbox enabled; Hardened Runtime enabled',
    'producer_bundle': str(app),
    'cases': results,
    'limitations': [
        'Synthetic store and authorizer; no real credentials or OS approval UI.',
        'Development sandbox proof, not a notarized production app test.',
    ],
}
(proof / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
print('Proof file: ' + str(proof / 'result.json'))
PY
