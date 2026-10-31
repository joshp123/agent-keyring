<!-- Written by AI on 2026.10.31 by model gpt-6.1-sol. -->

# Mac relay approver system proof

Run on the physical Mac mini with dummy example.com credentials. The Swift
fixture uses the production relay transport, TLS identity, HPKE, decision
checks, persisted state and outbox. It substitutes a software signing key and
counts authorizations; it does not claim to prove Touch ID or Secure Enclave
authentication. No real Passwords mirror is opened. Keychain records are
non-synchronizable and device-only, under fixture-specific service names.

The combined Go driver starts the real relay, controls the Swift fixture as an
owner would, and acts as an independently implemented enrolled receiver. With
`--cli`, it also runs the real Go CLI. With `--browser-script`, signed headless
Chrome completes a two-step login against the local dummy site.

The complete command exited 0, including these observations:

- First-setup fingerprints computed by Swift and Go match in all eight groups;
  Go verifies the human-signed initial key set.
- Machine enrolment independently compares the fingerprint and verifies the
  signed decision and complete published roster.
- The actual CLI enrols, asks for program access once, suppresses an echoing
  child, executes a retried operation once, and releases.
- After the relay is killed, one approval commits a signed, sealed answer.
  Killing/restarting the Mac fixture preserves its exact hash and authorization
  count. Restoring the relay delivers those same bytes. Go verifies the
  signature and request binding and opens the Swift HPKE bundle and all 30
  minutes of precomputed TOTP windows. No seed is sent.
- Restarting both processes preserves the absolute deadline. A duplicate
  BeginOperation returns its saved operation and no value.
- Plain Deny uses no authorization. Deny with a reply uses one and returns a
  verifiable signed reply. Hold-off survives tasks; ClearDenial clears both
  relay and local denied-history timestamps.
- Automatic uses no authorization under the current signed grant. Changing
  the Mac's rule to Ask stops new automatic delivery before publication.
- The actual CLI privately reads the Swift-sealed password and current code.
  Chrome submits the password, navigates, retries with one password POST, then
  submits TOTP and reaches the authenticated page. The lease is released.
- The remote lease list shows active access. End while offline immediately
  shows Revoked, survives a Mac restart, reaches the restored relay with no
  authorization, and refuses a new delivery.
- A Go peer acting as the new phone computes the same pairing fingerprint as
  the Mac. One authorization signs the next approver set, preserves its rule
  owner and binds the exact signed roster. The actual CLI advances its pinned
  key chain. This is not a physical iPhone proof.
- Publishing a roster without a revoked receiving machine refuses that client.

The local socket authority proof was also rerun after the denial-history fix:
all methods, restart/operation receipts, cancellation, rule revocation, denial
clearing, JSON migration and edited/rolled-back disk-state refusal passed.

The Xcode app builds on the mini with signing disabled, including the universal
Go helper. Unit tests were not run. This proof checks deadline values across
restarts; it does not wait out the full ten- or thirty-minute periods.

## Build the combined tree

Use this branch merged with the relay and client lanes. The proof that first
completed includes main's interrupted-lock fix and lease streaming implementation
(`3760a8e`, `c4555f0`, and `85883f0`). The proof binaries use lane-specific paths;
no shared `/tmp/agent-keyring-relay` binary is used.

From the MacBook checkout:

```sh
rsync -az --exclude=.git --exclude=.private --exclude=.build --exclude=build \
  --exclude=.devenv --exclude=.direnv ./ \
  mac-mini:code/agent-keyring-mac-approver-proof/
ssh mac-mini 'cd code/agent-keyring-mac-approver-proof/AgentKeyringPackage && \
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift build --product agent-keyring-relay-approver-fixture'
devenv shell -- go build -o /tmp/keyring-mac-r3-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-mac-r3-client ./cmd/agent-keyring
devenv shell -- go build -o /tmp/keyring-mac-r3-proof ./developer/mac-approver-proof
rsync -az /tmp/keyring-mac-r3-relay /tmp/keyring-mac-r3-client \
  /tmp/keyring-mac-r3-proof mac-mini:/tmp/
```

## Sign only the mini-built fixture

The mini has no signing identity. Use the existing Developer ID identity and
production app profile on the MacBook, as authorized for these dummy proofs.
No certificate or profile changes are needed. The wrapper has no extension,
is kept outside `/Applications`, is never launched on the MacBook, and is
trashed locally once copied. The installed app remains untouched.

```sh
mkdir -p /tmp/KeyringRelayProof.app/Contents/MacOS
rsync -az mac-mini:code/agent-keyring-mac-approver-proof/AgentKeyringPackage/.build/debug/agent-keyring-relay-approver-fixture \
  /tmp/KeyringRelayProof.app/Contents/MacOS/RelayApproverFixture
python3 - <<'PY'
import plistlib
from pathlib import Path
root = Path('/tmp/KeyringRelayProof.app/Contents')
with (root / 'Info.plist').open('wb') as file:
    plistlib.dump(dict(CFBundleIdentifier='com.joshpalmer.AgentKeyring',
        CFBundleExecutable='RelayApproverFixture', CFBundlePackageType='APPL',
        CFBundleName='RelayApproverFixture', CFBundleVersion='1', LSUIElement=True), file)
with Path('/tmp/keyring-relay-proof.entitlements').open('wb') as file:
    plistlib.dump({'com.apple.application-identifier':
        '7M8BR7R488.com.joshpalmer.AgentKeyring',
        'com.apple.developer.team-identifier': '7M8BR7R488',
        'com.apple.security.app-sandbox': True,
        'com.apple.security.network.client': True,
        'com.apple.security.network.server': True}, file)
PY
cp "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/faaab61c-9942-415f-aac5-6262347574a1.provisionprofile" \
  /tmp/KeyringRelayProof.app/Contents/embedded.provisionprofile
codesign --force --options runtime --timestamp=none \
  --sign 'Developer ID Application: Josh Palmer (7M8BR7R488)' \
  --entitlements /tmp/keyring-relay-proof.entitlements /tmp/KeyringRelayProof.app
rsync -az /tmp/KeyringRelayProof.app mac-mini:/tmp/
trash /tmp/KeyringRelayProof.app
pluginkit -mAv -p com.apple.authentication-services-credential-provider-ui
```

Only `/Applications/AgentKeyring.app` should remain registered on the MacBook.
The mini must have its console session unlocked for data-protection Keychain
access. Use the operate-mac-mini skill's existing unlock route when required.

## Run on the mini

Use a fresh root basename every run: fixture Keychain service names include
that basename. The sandbox requires state inside the app container. The driver
owns port 17445, starts/stops its relay and fixture, and the browser proof owns
port 8443 and its temporary Chrome profile. Other lanes use other ports.

```sh
/tmp/keyring-mac-r3-proof \
  --root "$HOME/Library/Containers/com.joshpalmer.AgentKeyring/Data/mac-r3-proof-1" \
  --approver /tmp/KeyringRelayProof.app/Contents/MacOS/RelayApproverFixture \
  --relay /tmp/keyring-mac-r3-relay --cli /tmp/keyring-mac-r3-client \
  --browser-script "$HOME/code/agent-keyring-mac-approver-proof/script/prove_mac_relay_browser.py"
```

For a manual joint proof, start the relay with `--listen 127.0.0.1:17445
--state UNIQUE_ROOT/relay --loopback-test`. Hold stdin open for
`RelayApproverFixture --dummy-only UNIQUE_CONTAINER_ROOT`. Its tab-separated
commands are `pair PORT`, `confirm FULL_FINGERPRINT`, `enrol DIGEST
FULL_FINGERPRINT true|false`, `publish`, `approve REQUEST_DIGEST`, `deny
REQUEST_DIGEST [reply]`, `clear RECIPIENT_ID`, `end LEASE_ID`, `revoke
RECIPIENT_ID`, `rule auto|ask|block`, `confirm-approver KEY_ID FULL_FINGERPRINT`,
`status`, `saved`, and `quit`. It reports READY, locally computed fingerprints,
request/lease states, queue count and authorization count; never secrets.

The CLI connects with `AGENT_KEYRING_RELAY=127.0.0.1:17445` and an isolated
`AGENT_KEYRING_STATE_DIR`. Unset `AGENT_KEYRING_SOCKET` for a relay proof. The
dummy login ID is `00000000-0000-0000-0000-000000000301`, initially Ask.

Afterward stop owned processes, trash the fixture app, unique dummy roots and
binaries on the mini, and unregister/trash any Xcode-built proof app. The mini
should have no registered Agent Keyring extension. Tiny isolated Keychain
checkpoints may remain; production uses other services. Close any unlock
connection this proof started.

## Josh's remaining checks

Touch ID with the panel's LAContext, cancellation during hardware evaluation,
multiple signatures under one authorization, and Automatic enclave signing
without interaction need the real MacBook. Also check locked-session refusal
and Watch behavior. The physical iPhone pairing screen and cellular approval
belong to the phone/device proof. No new certificate, profile, installation or
release was performed here.

## Pairing cancellation and resolved-address proof

The short `--pairing-controls` run passed on the mini after the U4 binding
changes. It uses the same fixture and real relay, without the CLI/browser run.
Build `developer/mac-approver-proof` and `cmd/agent-keyring-relay` as above.
Set `AGENT_KEYRING_PROOF_TAILNET_HOST` to the mini's own MagicDNS name at
runtime (for example, read `Self.DNSName` from `tailscale status --json`), then
add `--pairing-controls` to the driver command with a fresh root.

- A hostname resolving to the mini's Tailscale address reaches comparison.
  A TLS listener on its LAN address and one on default loopback both observe
  connection closure with zero protobuf bytes. The explicit proof-loopback
  option works and remains enabled after fixture restart.
- Abandoning an unconfirmed setup clears its comparison and leaves it
  unpaired after restart. Starting again then completes first pairing.
- A dismissed phone-pairing ID stays absent when the relay replays its backlog
  after reconnect and after restart. A second pending phone pairing still
  appears. Trying to confirm the dismissed ID fails, with no authorization
  and no queued confirmation.

The MacBook resolves the short name `mac-mini` over MagicDNS; the mini itself
resolves that short name to its LAN address. The latter route is correctly
refused. No private tailnet DNS name is stored in the repository.
