# Replacing an approval-only phone pairing

Written by AI on 2026.11.01 by model gpt-6.1-sol.

The actual Swift phone core upgraded a pairing created by the previous
approval-only Swift build, then delivered a current copied login to the real
Go receiver through the real relay. The proof ran headless on the Mac mini.
The unsigned iOS Release build passed. Nothing was installed or launched on
the iPhone.

## Settings entry point

`PhoneKeyringBackend.beginReplacementPairing() async throws` starts replacement
on the existing relay. The designer can call the matching
`PhoneKeyringModel.beginReplacementPairing() async` and show the existing
pairing screen. There is no endpoint argument and no new pairing state.

This is an explicit action: normal `beginPairing(endpoint:)` still refuses an
already paired phone. Replacement discards the old local requests, history,
copy and outbox. It keeps the relay pin and the old phone key ID, records that
new keys are needed, and creates fresh signing, TLS and sealing keys. That
receipt is durable before any old key is removed. A failed reset can retry;
it never restores the retired local identity. Cancel and reopen retain the
fresh keys and comparison receipt.

The usual fingerprint comparison and Mac signature authorize the fresh phone.
The phone also requires its previous key to be absent from the signed result.
Appending the new key while retaining the previous one is not replacement.
No old key gains an encryption key, and no role or wire message changes.
Keychain items remain non-synchronizable and device-only. Push registration is
renewed for the new identity after pairing.

The current Mac `confirmApproverPairing` adds a phone but does not expose an
old-phone replacement action. That integration gap was reported to the
orchestrator; this lane leaves the Mac and the views untouched. The proof's
Mac substitute uses the existing signed `PublishApproverKeys` operation to
remove the old phone and add the new one in a single publication. Actual Mac
Touch ID and the Settings control remain integration/device checks.

## Headless operating proof

The legacy fixture is built from published build 8 source `6e09b58`. It really
pairs with role PHONE and an empty encryption key and completes pairing before
the current binary starts. The current code reads that existing saved state;
the fixture does not invent a legacy pairing by editing its plist.

The full existing Swift phone proof runs from that pairing, including
approval-only delivery. The replacement phase then checks:

- The new backend action works while paired and drops old local requests.
- Signing, TLS and sealing keys all change. Go and Swift compare identical
  encryption-key-bound transcripts.
- Cancel, process restart and re-entry keep the fresh comparison and keys.
- The Mac-signed replacement is accepted without phone authorization.
- The retired TLS identity cannot fetch copies, register push or submit a
  decision. The fresh phone can answer.
- A current copy reaches the fresh phone without authorization. One software
  authorization opens it and signs HUMAN delivery; the real Go receiver opens
  the current password and verification code.

The subsequent copy proof also passes refresh/reopen, missing or stale copy
fallback, decrypted site mismatch refusal, both Mac/phone race orders,
lost-acknowledgement recovery through relay and phone restarts, and delivery
after the last Mac watcher disconnects. Only biometric keys and Mac signing
are software substitutes; phone trust, storage, request handling, HPKE and
outbox behavior are production Swift code.

Build the legacy fixture in an isolated directory from `6e09b58`, and the
current fixture and relay from this checkout, then run:

```sh
/tmp/phone-upgrade-fixture --mode phone --relay /tmp/phone-upgrade-relay \
  --phone-binary "$PWD/AgentKeyringPackage/.build/debug/agent-keyring-phone-fixture" \
  --legacy-phone-binary /PATH/TO/LEGACY/AgentKeyringPackage/.build/debug/agent-keyring-phone-fixture
```

Both Swift builds use
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
--package-path AgentKeyringPackage --product agent-keyring-phone-fixture`.
The mini used its existing Nix Go toolchain. The fixture chooses an ephemeral
loopback port, with the explicit proof transport override; no service or
screen was used.

Logs are in the main checkout at `.private/proofs/r8-phone-replacement/`:
`phone-upgrade-joint.log`, `phone-upgrade-swift-build.log`,
`phone-upgrade-legacy-build.log`, `phone-upgrade-ios-summary.log` and the full
`phone-upgrade-ios-build.log`, which ends in BUILD SUCCEEDED. The retained
`phone-upgrade-first-fixture-failure.log` shows why the legacy binary must
finish its initial pairing before the upgrade: restarting the new binary
mid-comparison adds an encryption key to the old request and is refused.

Real Secure Enclave key replacement, Face ID and Mac Touch ID remain unproved
by this software-key run. No Apple account, certificate, signing or physical
phone change was made.
