# Automatic login copies from the Mac

Written by AI on 2026-11-01 by model gpt-6.1-sol.

## Result

The production Swift Mac approver, real Go relay and an independent Go HPKE receiver
passed the headless copy-update proof on the physical Mac mini. Mac production
code is from `30a0a5f`, with the relay contract `7dbdbcf` and implementation
`e23e829` (cherry-picked here as `a99b96d` and `d7da1c2`). The fixture replaces
biometrics with isolated software signing keys. It uses an encrypted dummy mirror
and synthetic Apple credential-exchange data, never Apple Passwords or real data.

The driver checked:

- Initial pairing compares the Swift/Go fingerprint and publishes the mini's
  exact signing/encryption keys from that same TLS pairing stream.
- A confirmed Automatic rule queues a background-signed, HPKE-sealed password
  and TOTP-seed copy after its configuration. The Go receiver opens the resulting
  relay delivery and verifies the signature, login, password and code deadlines.
- A password refresh enters through `MirrorAppModel.receive` and the production
  mapper, merger, encrypted save and import handler. The next delivery on the
  existing Automatic lease contains the new password. No human authorization is
  requested, the configuration remains unchanged, and the lease deadline stays
  fixed. One background signature creates the copy update.
- A transparent TLS proxy drops the acknowledgement after the relay commits
  that update. The Mac continues to show Applying. Killing and restarting both
  the Mac fixture and relay retains the exact signed update/ciphertext and its
  revision. The outbox resends it, completes and clears Applying, without another
  authorization or signature. Delivery still contains the refreshed password
  under the original lease deadline.
- Automatic to Ask removes the mini's copy and revokes the existing Automatic
  lease before acknowledgement. With the Mac disconnected, a new request stays
  pending. Ask to Automatic republishes the refreshed copy; a new request is
  active and delivers with the Mac disconnected.
- Automatic to Blocked removes access and revokes the active lease. With the
  Mac disconnected, the mini denies new requests.

Full Swift package build, `go vet ./...` and all 18 focused import/save/reporting
tests passed as well. Logs are retained locally in `.private/proofs/round9/`:
`copy-proof.log`, `swift-build.log`, `package-build.log`, `import-tests.log` and
`cleanup.log`.

## Implementation

Configuration changes commit their configuration, full copy replacement and
local rule/lease changes to the existing authority checkpoint and outbox. Copy
revisions increase per destination across configuration changes. A password-only
import needs no signed configuration and uses only the existing background
delivery key, with interaction disabled.

The checkpoint records which imported generation and configuration have a queued
copy. Import/startup reconciliation queues a replacement for a newer imported
generation, including after a crash between mirror save and queueing. This sends
one full replacement per import generation, including unchanged imports, without
storing a plaintext password digest or adding a separate queue.

`isApplying` includes copy updates until acknowledged; `queuedAnswerCount`
excludes them. No screen API or additional approval control is needed. An
existing pairing that still delegates Automatic decisions to the Mac uses the
existing Confirm your rules band to confirm delegation to the mini's keys.

## Replay

Build the production Swift fixture on the mini and sign its wrapper using the
existing Developer ID profile, as described in [the Mac approver proof](mac-relay-approver.md).
Never launch that wrapper on the MacBook. From the same source tree, build:

```sh
go build -o build/proof/relay ./cmd/agent-keyring-relay
go build -o build/proof/mac-approver-proof ./developer/mac-approver-proof
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift build --package-path AgentKeyringPackage \
  --product agent-keyring-relay-approver-fixture
```

With a fresh `relay-proof-` root inside the app's container and unused loopback
ports 17445 (relay) and 17455 (proxy), run on the mini:

```sh
build/proof/mac-approver-proof --copy-updates \
  --root "$DUMMY_ROOT" \
  --approver "$SIGNED_WRAPPER/Contents/MacOS/RelayApproverFixture" \
  --relay "$PWD/build/proof/relay"
```

The driver owns and stops its processes. Erase only its uniquely named,
non-synchronizable Keychain items with the signed fixture's
`--erase-dummy-checkpoints "$DUMMY_ROOT"`, then move that root, wrapper, source
copy and binaries to Trash. Leave the installed app and its state untouched.

This proof used no screen, native input, app installation or hardware keys.
Actual Apple export, Touch ID and Secure Enclave signing while locked remain
device checks. The relay lane separately exercises rejected replay/signature/
destination cases and real CLI/headless Chrome sign-in with the Mac disconnected.
