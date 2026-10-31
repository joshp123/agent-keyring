<!-- Written by AI on 2026.10.31 by model gpt-6.1-sol. -->

# Mac lease authority proof

The proof uses the production socket, lease store, encrypted mirror and
data-protection Keychain checkpoint. A separate Go process calls the socket and
kills/restarts the authority. The fixture has only synthetic example.com data.
Its rule signer is a fixture, and it refuses successful biometric approval.
The existing signed-rule implementation and successful Touch ID are separate
checks. No real vault is opened, and no app is installed.

Observed on the Mac mini, with Xcode 27 beta:

- Automatic approval, fixed 30-minute deadline, task joining and retry conflicts.
- Active and pending records survive restart with their original deadlines.
- Started is committed before delivery; a restart/retry returns the record and
  no value. Finish is idempotent, conflicting results fail, and the exit code
  survives release. GetOperation starts nothing and rejects key/digest conflicts.
- Purpose/field checks and whole-operation refusal when a field is unavailable.
- Watch initial/terminal updates, owner denial with reply, suppression across
  tasks/purposes and restart, deliberate clearing, cancellation, rule revocation.
- Owner ending access records Revoked; agent release records Released. Request
  and end times survive restart. Cancelled/failed approvals leave Pending, then
  Deny preserves its reply. The cancellation check does not prove an in-flight
  hardware evaluation: that needs Josh's Touch ID session.
- Every authority method round-trips. Receiver-only methods are rejected.
  Old JSON clients get the new lease command; malformed frames are closed.
- Both modified snapshot files and restored older valid snapshots are rejected
  against the app-private checkpoint. Restoring the actual committed files
  restores the original records; failure never creates a new authority.
- The real Go CLI privately consumes `read`, suppresses an echoing child's
  output, reuses its program receipt after authority restart, and releases.
- The real Go CLI and signed headless Chrome complete password then TOTP with
  the Swift authority. After password submission/navigation and authority restart,
  retry reports the saved receipt and the server sees one password POST. The
  authenticated page is checked before release.
- The Xcode app builds on the mini, bundles the universal Go helper at
  `Contents/Helpers/agent-keyring`, and contains no XPC fill helper. The package,
  including the remaining test targets, compiles; unit tests were not run.

The 10/30-minute deadlines are checked for fixed values across restart. This
proof does not wait out those full periods. Successful Ask activation, Touch ID
from the non-activating panel, and real Codex/Claude sign-ins remain device and
release proofs.

## Build and sign the isolated fixture

Use a combined checkout with the Go CLI lane. Build the app and fixture on the
mini, with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
The Go build script produces `build/cli/macos/agent-keyring`.

```sh
cd AgentKeyringPackage
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift build --product agent-keyring-authority-fixture
```

An unsigned command-line executable cannot use the app-private data-protection
Keychain. For this proof Josh authorized the existing production Developer ID
profile and identity, with signing on the MacBook and execution only on the mini.
No certificate/profile/account changes are needed. The proof wrapper contains
no credential extension and is never launched on the MacBook.

On the MacBook, fetch only the mini-built executable. In the commands below the
mini checkout is `/Users/josh/code/agent-keyring-r2-authority`.

```sh
mkdir -p /tmp/KeyringProof.app/Contents/MacOS
rsync -az mac-mini:/Users/josh/code/agent-keyring-r2-authority/AgentKeyringPackage/.build/debug/agent-keyring-authority-fixture \
  /tmp/KeyringProof.app/Contents/MacOS/AuthorityFixture
python3 - <<'PY'
import plistlib
from pathlib import Path
root = Path('/tmp/KeyringProof.app/Contents')
with (root / 'Info.plist').open('wb') as file:
    plistlib.dump(dict(CFBundleIdentifier='com.joshpalmer.AgentKeyring',
        CFBundleExecutable='AuthorityFixture', CFBundlePackageType='APPL',
        CFBundleName='AuthorityFixture', CFBundleVersion='1'), file)
with Path('/tmp/keyring-proof.entitlements').open('wb') as file:
    plistlib.dump({'com.apple.application-identifier':
        '7M8BR7R488.com.joshpalmer.AgentKeyring',
        'com.apple.developer.team-identifier': '7M8BR7R488',
        'com.apple.security.app-sandbox': True,
        'com.apple.security.network.server': True}, file)
PY
cp "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/faaab61c-9942-415f-aac5-6262347574a1.provisionprofile" \
  /tmp/KeyringProof.app/Contents/embedded.provisionprofile
codesign --force --options runtime --timestamp=none \
  --sign 'Developer ID Application: Josh Palmer (7M8BR7R488)' \
  --entitlements /tmp/keyring-proof.entitlements /tmp/KeyringProof.app
rsync -az /tmp/KeyringProof.app mac-mini:/tmp/
trash /tmp/KeyringProof.app
pluginkit -mAv -p com.apple.authentication-services-credential-provider-ui
```

The last command must still show only the installed `/Applications/AgentKeyring.app`
extension. Keep the proof outside `/Applications`. Signing here does not notarise,
publish or install anything.

## Run the two proofs on the mini

Build `developer/authority-proof` using the repo's pinned Go toolchain, then copy
the executable to `/tmp/keyring-authority-proof` on the mini. Run there:

```sh
/tmp/keyring-authority-proof \
  --authority /tmp/KeyringProof.app/Contents/MacOS/AuthorityFixture \
  --root "$HOME/Library/Containers/com.joshpalmer.AgentKeyring/Data/r2-socket-1" \
  --cli /Users/josh/code/agent-keyring-r2-authority/build/cli/macos/agent-keyring

cd /Users/josh/code/agent-keyring-r2-authority
python3 script/prove_mac_authority_cli.py \
  --authority /tmp/KeyringProof.app/Contents/MacOS/AuthorityFixture \
  --root "$HOME/Library/Containers/com.joshpalmer.AgentKeyring/Data/r2-browser-1" \
  --cli build/cli/macos/agent-keyring
```

Use a fresh short root basename for each run. The socket is `ROOT/agent.sock`;
the real CLI selects it through `AGENT_KEYRING_SOCKET`. The sandbox requires the
root inside that container. The socket proof deliberately modifies its files at
the end, so its root cannot be reused. The browser proof needs port 8443 free
and the Go lane's `script/prove_cli.py` CDP driver. Chrome uses a temporary
profile; all started processes are stopped.

For a custom client, start `AuthorityFixture ROOT` with stdin held open, wait for
`Ready: ROOT/agent.sock`, and set `AGENT_KEYRING_SOCKET`. `--with-code` adds a
synthetic saved TOTP and the loopback site. Initial policy is Automatic. Owner
stdin commands are `ask`, `auto`, `block`, `deny LEASE optional reply`,
`clear-denial`, `revoke LEASE`, and `quit`. `cancel-approval LEASE` and
`failed-approval LEASE` exercise unsuccessful public model calls. None approves
biometrics. Keychain checkpoints use the distinct service
`com.agentkeyring.authority-fixture.ROOT_BASENAME`, explicitly non-synchronizable
and device-only. They cannot sync into the MacBook's real app state.

After the proofs, trash `/tmp/KeyringProof.app` on the mini and remove the mini's
Xcode proof app from Launch Services before trashing it. Leave the installed
MacBook app and its extension alone. Tiny fixture checkpoint items can remain
in the mini's Keychain; the production authority uses another service.

## Screen interface

`MirrorAppModel.leaseStore` is observable on the main actor. It exposes `leases`,
`waitingRequests`, `activeLeases`, `changes()` (current snapshot first), and
`requester(for:)`. Leases include request/end times. U2 uses
`approveLeaseWithTouchID(id, context: LAContext)` with its panel context, or the
no-context overload for the existing system prompt. Both check current signed
rules after authentication and reject cancellation/late answers. Only
`denyLease(id, reply:)` denies. U3 uses `revoke(id)` for Josh's End action and
`clearDenial(loginID:)` to clear the local hold-off. Set
`automaticallyPromptForLeases = false` when U2 owns the panel.
