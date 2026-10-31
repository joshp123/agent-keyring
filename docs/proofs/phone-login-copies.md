# iPhone delivery from sealed Ask copies

Written by AI on 2026.11.01 by model gpt-6.1-sol.

The actual Swift phone core passed against the real Go relay and Go receiver
on the Mac mini, headless over SSH. The iOS Release build also passed, with
signing disabled. Nothing was installed or launched on the iPhone.

This extends the [build 8 approval-only proof](iphone-relay-approver.md).
The parent worktree was merged with main at `6676e59`, then integrated the
contract `3146922` and relay changes `57bf9cd` and `9329354`.

## What ships in the phone code

- Pairing binds the phone's P-256 agreement public key after the exact key-set
  bytes in the comparison transcript. Its destination is lowercase SHA-256 of
  the 65 X9.63 public-key bytes. Empty agreement keys retain the original
  transcript and approval-only behavior.
- The agreement key uses Secure Enclave, `biometryCurrentSet`,
  `WhenUnlockedThisDeviceOnly` and non-synchronizable Keychain storage.
  Opening a copy and signing its delivery share one fresh Face ID context.
  After authentication, either operation fails instead of prompting again.
- Connect and approval refresh the trusted key chain, rule-owner configuration
  and retained copy. Copy updates need a current MAC_DELIVERY signature, the
  phone's own destination, the exact current configuration revision, increasing
  copy revisions, unique current Ask login IDs and matching receiver IDs.
  An exact update retry is allowed. Opening checks the login ID, saved sites
  and verification-code presence against that configuration.
- Only the signed encrypted snapshot is saved, atomically with complete file
  protection and excluded from backup. Replacements replace the full snapshot.
  Stale copies lose their payload while retaining the highest revision and
  update digest, so removing a payload does not permit a rollback.
- A remote approval with a current copy opens that login, generates only the
  leased verification codes, seals the bundle to the current enrolled receiver
  and signs a HUMAN decision. The delivered bundle contains no code seed.
  Local requests and missing or stale copies retain approval-only Mac delivery.
- Remote plain Deny goes directly through unsigned APPROVER_CONNECTION Decide;
  a reply uses a Face ID signed HUMAN decision. Neither needs a copy.
- The outbox persists the exact signed decision and wire command before sending.
  A lost acknowledgement or a competing answer is resolved by the relay's actual
  lease. Reconnect never creates a second authorization or extends the deadline.

There is no view or `PhoneKeyringBackend` shape change. Direct deliveries show
`sendingAnswer` until a committed outcome arrives. Fallback approvals retain
`waitingForMac` until the Mac commits. The displayed winner and denial reply
come from the committed lease.

## Operating proof

`script/relay_fixture/phone.go` drives the actual `PhoneRelayApprover` process;
`phone_swift_copy.go` adds the copy and direct-delivery phase. Software P-256
keys replace only the biometric keys. The fixture checks that opening and
signing receive the same authorized `LAContext`, and counts authorizations.
All credentials and identities are dummy fixture data. The production phone
request, trust, copy, sealing and durable outbox code runs unchanged.

Passed:

1. Swift and Go compare the same encryption-key-bound pairing transcript;
   the existing receiver accepts the resulting key chain.
2. No copy: one authorization sends phone consent, the phone waits for the Mac,
   and the real receiver verifies the two signatures and opens the delivery.
   The original lost-acknowledgement and configuration-refusal checks still pass.
3. A signed copy arrives with no authorization. One authorization opens it and
   signs direct HUMAN delivery. The real receiver opens the current password
   and a verification code.
4. A password-only update reaches the phone without authorization. After process
   restart, the next delivery uses the changed password. An older update replay
   is refused. A signed envelope with wrong decrypted sites cannot grant access.
5. Advancing the configuration without a fresh copy makes the copy unavailable.
   Approval falls back to the Mac on the same lease with one authorization.
6. The phone commits first. A competing Mac Decide returns that same phone lease.
   A proxy discards the phone's acknowledgement after commit. With relay and
   phone restarted, the exact queued Decide succeeds without another
   authorization. The real receiver opens that delivery.
7. The Mac commits while phone authorization is held. The phone's watch is stopped
   so its losing Decide actually reaches the relay. The Swift phone displays
   the committed Mac outcome without a second authorization.
8. A pending request is not explicitly escalated. Closing the last Mac WatchWork
   connection sends it to the actual Swift phone. With the Mac disconnected,
   one authorization delivers a bundle the real receiver opens. End Access works.
9. Remote plain denial, signed denial reply, scoped clear, local approval and
   actual Mac outcome reporting continue to pass.

Reproduce from the repository root with Xcode beta and the project's Go toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift build --package-path AgentKeyringPackage \
  --product agent-keyring-phone-fixture
devenv shell -- go build -o /tmp/keyring-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-relay-fixture ./script/relay_fixture
/tmp/keyring-relay-fixture --mode phone --relay /tmp/keyring-relay \
  --phone-binary "$PWD/AgentKeyringPackage/.build/debug/agent-keyring-phone-fixture"
```

The run used the mini's existing Nix-profile Go directly. It ran in the isolated
mirror `~/from-macbook/agent-keyring-phone-copies`, with explicit loopback proof
transport. The normal transport's resolved-address tailnet check passed first.
No simulator, app window or other display surface was opened.

Logs are preserved in the main checkout at
`.private/proofs/r7-phone-copies/`: `joint.log`, `swift-build.log`,
`ios-build-summary.log` and the full `ios-build.log` ending in BUILD SUCCEEDED.
`first-fixture-failure.log` retains the first attempt: the new fixture omitted
the exact RequestRecord from EscalateToPhone. Correcting the fixture required
no production change.

## Still needs a device check

Actual Secure Enclave opening and signing with one Face ID, mobile data,
background notification delivery and the integrated Mac app's copy sender
remain unproved here. Software keys establish the shared-context operating path,
not iOS's biometric behavior. There was no signing, certificate, account or
physical-phone change in this round. Build 8 remains the installed phone build.
