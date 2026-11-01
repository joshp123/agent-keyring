# Replacing a paired phone from the Mac

Written by AI on 2026.11.01 by model gpt-6.1-sol.

The phone keeps its TLS identity and creates new signing and sealing keys.
`PairApprover` already carries the TLS public key, and the relay checks it against
the connecting peer. The Mac therefore replaces the existing PHONE with exactly
that TLS key. A new TLS identity is an addition. Labels do not select a phone.

`RelayApproverPairing` exposes `replacesPhoneKeyID` and `replacesPhoneLabel` for
the comparison panel. `confirmApproverPairing(id, comparedFingerprint:, context:)`
is unchanged. Its Touch ID reason names replacement. The signed replacement set
removes that old signing key, adds the new signing/sealing keys, and preserves
all other approvers and the signed configuration. The relay deletes the retired
phone's copy when it commits the set. The Mac removes unsent updates for that
retired destination in the same checkpoint that queues replacement and the new
Ask copy.

A queued replacement is also the source of truth for subsequent copy recipients.
If its acknowledgement is lost, a password refresh queues behind it for the new
phone. It cannot queue another update for the retired destination and block the
outbox. The exact signed set and updates survive restart; recovery does not need
another comparison, authorization or signature.

## Headless joint proof

Both replacement modes passed on the physical Mac mini. The proof checked:

- Identical Swift fingerprints and an explicit replacement reason; a wrong
  fingerprint fails before authorization, and confirmation authorizes once.
- The old signing key is absent; its copy is deleted. Another phone with the
  same name, all Mac keys and the exact signed configuration stay unchanged.
- An actual synthetic import while the replacement acknowledgement is lost
  queues copies only for current destinations. Applying remains visible.
- Mac and relay restarts retain the exact queued signed key set. Recovery needs
  no further authorization or background signature and clears Applying.
- With the Mac exited, the replacement phone delivers the refreshed password
  and saved TOTP. The production Go receiver advances the signed key chain and
  opens them. Phone restart preserves that outcome and the exact delivery.
- A genuine approval-only pairing created by Swift build `6e09b58` upgrades
  through the same flow, without editing its saved pairing state.

The Ask-copy and Automatic-copy system proofs passed again. The full Swift
package build and `go vet ./...` passed. Logs are retained in this checkout
under `.private/proofs/round11/`.

The driver uses the production Swift Mac and phone cores, the real Go relay and
the production Go receiver. Software keys stand in for Touch ID and Face ID.
`--phone-replacement` exercises a phone that already holds a copy. Add
`--legacy-phone-binary` to create the first pairing with the old approval-only
Swift fixture from `6e09b58`, then open that exact saved state with current code.

Build and sign the mini-built Mac wrapper as described in
[the Mac approver proof](mac-relay-approver.md). Do not launch it on the MacBook.
Build the current phone fixture, relay and driver from this checkout. With
unused proof ports 17445 and 17455, run on the mini:

```sh
mac-approver-proof --phone-replacement \
  --root "$HOME/Library/Containers/com.joshpalmer.AgentKeyring/Data/relay-proof-r11p1" \
  --approver "$SIGNED_WRAPPER/Contents/MacOS/RelayApproverFixture" \
  --relay "$RELAY_BINARY" --phone-binary "$PHONE_BINARY"
```

Repeat with a fresh short root and
`--legacy-phone-binary "$LEGACY_PHONE_BINARY"` for the approval-only upgrade.
The driver stops its processes. Erase only its root's isolated checkpoints with
`RelayApproverFixture --erase-dummy-checkpoints "$ROOT"`, then move the dummy
state, binaries and signed wrapper to Trash. Leave the installed app, relay
service and real credentials untouched.

The retained TLS identity intentionally represents the newly paired phone. It
is not retired; the old signing and sealing identities are. Real hardware key
rotation and the pairing panel remain device/interface checks.
