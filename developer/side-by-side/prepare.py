#!/usr/bin/env python3
# Written by AI on 2026.11.01 by model gpt-6.1-sol.
"""Package an already-built Release app for an isolated, real-product session.

No app is launched. No profile, certificate, installed app or CLI link is changed.
The source app must already have the dedicated test bundle identity.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

BUNDLE_ID = 'com.joshpalmer.KeyringTest.AgentKeyring'
TEAM_ID = '7M8BR7R488'


def run(*arguments):
    subprocess.run(list(map(str, arguments)), check=True)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--profile', required=True, type=Path)
    parser.add_argument('--identity', required=True, help='Existing Apple Development SHA-1')
    args = parser.parse_args()
    source, app = args.source_app.resolve(), args.output.resolve()
    source_info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if source_info['CFBundleIdentifier'] != BUNDLE_ID:
        parser.error('Build with the test identity first. Do not rename a production-identity build.')
    if app.exists():
        parser.error('Output already exists; choose a fresh test directory.')
    profile_bytes = subprocess.check_output(['/usr/bin/security', 'cms', '-D', '-i', args.profile])
    profile = plistlib.loads(profile_bytes)
    allowed_id = profile['Entitlements']['com.apple.application-identifier']
    if allowed_id not in [f'{TEAM_ID}.*', f'{TEAM_ID}.{BUNDLE_ID}']:
        parser.error('Profile does not authorize the isolated application identifier.')
    allowed_signers = [hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']]
    if args.identity.upper() not in allowed_signers:
        parser.error('Profile does not authorize the supplied existing signing identity.')
    app.parent.mkdir(parents=True, exist_ok=True)
    run('/usr/bin/ditto', source, app)
    plugins = app / 'Contents/PlugIns'
    if plugins.exists():
        run('/usr/bin/trash', plugins)
    if list(app.rglob('*.appex')):
        parser.error('An extension remains in the test package.')
    info = dict(source_info)
    info.update(CFBundleDisplayName='Agent Keyring Test', CFBundleName='Agent Keyring Test',
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                SUFeedURL='https://127.0.0.1:9/agent-keyring-test-disabled.xml')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copyfile(args.profile, app / 'Contents/embedded.provisionprofile')
    entitlements = {
        'com.apple.application-identifier': f'{TEAM_ID}.{BUNDLE_ID}',
        'com.apple.developer.team-identifier': TEAM_ID,
        'keychain-access-groups': [f'{TEAM_ID}.{BUNDLE_ID}'],
        'com.apple.security.app-sandbox': True,
        'com.apple.security.network.client': True,
        'com.apple.security.network.server': True,
    }
    entitlements_path = app.parent / 'test-entitlements.plist'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    # Sign each executable, then its enclosing code bundle, from the inside out.
    # Sparkle remains the shipped dependency; its feed cannot reach a release.
    executable_magic = [bytes.fromhex(value) for value in
                        ['cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca', 'feedfacf', 'feedface']]
    for path in sorted(app.rglob('*'), key=lambda path: len(path.parts), reverse=True):
        if path == app / 'Contents/MacOS' / info['CFBundleExecutable']:
            continue  # Signing the main executable seals the whole outer bundle.
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as source_file:
            is_executable = source_file.read(4) in executable_magic
        if is_executable:
            run('/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp', '--preserve-metadata=entitlements', '--sign', args.identity, path)
    nested_bundles = [path for path in app.rglob('*') if not path.is_symlink()
                      and path.suffix in ['.xpc', '.app', '.framework'] and path.is_dir()]
    for path in sorted(nested_bundles, key=lambda path: len(path.parts), reverse=True):
        run('/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp', '--preserve-metadata=entitlements', '--sign', args.identity, path)
    requirement = (f'identifier "{BUNDLE_ID}" and anchor apple generic and '
                   f'certificate leaf[subject.OU] = "{TEAM_ID}" and '
                   'certificate 1[field.1.2.840.113635.100.6.2.1]')
    run('/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', args.identity,
        '--entitlements', entitlements_path, '--requirements', '=designated => ' + requirement, app)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    relative_files = ['Contents/MacOS/AgentKeyring', 'Contents/Helpers/agent-keyring',
                      'Contents/Resources/AgentTools/AgentSkill/agent-keyring/SKILL.md']
    manifest = {'source_commit': args.source_commit, 'bundle_id': BUNDLE_ID,
                'profile_uuid': profile['UUID'], 'signing_identity': args.identity.upper(),
                'app_path': str(app), 'changes_from_release': [
                    'Dedicated test bundle identity and display name',
                    'Credential extension omitted', 'Automatic updates disabled; release feed replaced by loopback port 9'],
                'sha256': {name: sha256(app / name) for name in relative_files}}
    (app.parent / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Prepared and verified; NOT launched:', app)


if __name__ == '__main__':
    main()
