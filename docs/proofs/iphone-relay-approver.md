# Approval-only iPhone backend

Written by AI on 2026.10.31 by model gpt-6.1-sol.

The actual `PhoneRelayApprover` now signs answers; it does not open, seal or
send credentials. Its package target no longer depends on the phone vault.
The deferred phone vault, Passwords import and credential-provider extension
have been deleted. The Mac shared importer remains. The Mac holds and delivers
the password; phone pairing, requests and history need no phone import.

The phone uses a fresh Secure Enclave signing account with
`biometryCurrentSet` and `WhenUnlockedThisDeviceOnly`, a fresh non-synchronizable
TLS identity, and new approval-only state. Old generic approver state and keys
are not reused. This build must pair again. Public-key lookup does not sign;
each approval or denial reply uses a fresh Face ID context with no reuse
window. After authentication, signing cannot silently request another prompt.
Actual Secure Enclave and Face ID behavior remains a device check.

The unused CloudKit controller, QR pairing screen, signing adapter and
notification service extension have been deleted. Their CloudKit, camera and
time-sensitive notification capabilities are gone. The custom speech backend
and its permission strings are gone too. Opus's current views were untouched.

## Backend values

Pairing retains `beginPairing(endpoint:)`, `cancelPairing()` and
`PhonePairingState.comparing(fingerprint:relayAddress:)`. The candidate has role
PHONE. The phone verifies the Mac signature, exact comparison transcript and
bound signed configuration. `GetConfiguration` supplies the one snapshot of
logins, rules and enrolled machines. The phone verifies its domain, rule-owner
signature and revision, then atomically retains it with the verified key chain.
It rejects a lower revision and different exact bytes at the same revision,
including across restart. The old index and roster caches are gone; state v3
starts a fresh pairing for this unreleased contract. Local requests use the
trusted source Mac's label; remote requests use machines from the configuration.

`approve` and `deny` return and stream:

- `.sendingAnswer(choice)` before relay acknowledgement;
- `.waitingForMac(choice, reply:)` after acknowledgement while the lease is
  PENDING, preserving a typed denial reply;
- the actual `.approved` or `.denied` outcome after the Mac commits it.

The atomic outbox stores the exact serialized `SignedPhoneDecision` and wire
command before any network call after Face ID. Retries and restart reuse those
bytes. Plain Deny is unsigned over the pinned PHONE connection; a reply is
Face ID signed. Cancellation hints do not invent a terminal outcome. Elapsed
local deadlines affect display without overwriting the Mac's stored state.
End and Let it ask again retain the last actual local lease until the Mac's
report arrives.

`settings.rulesUpdatedAt` comes from a verified GetConfiguration receipt.
`settings.askPhoneAfter` stays nil because this protocol does not expose the
Mac's setting. Notification permission is requested after pairing. The OS
push token is refreshed on open and registered with the relay; one build setting controls both the
`aps-environment` entitlement and the registration's production flag.
Settings show `.on` only when iOS permission is granted and a remote relay
notification has actually been observed. Otherwise they show `.notSetUp`.
Foreground delivery, tapping a notification and the OS delivered-notification
list all record that receipt locally; local and former CloudKit notifications
do not count. A token registration acknowledgement never turns the setting on.
No live APNs notification was proved.

## Joint system proof

The integrated one-configuration flow passed on the physical Mac mini from
main's production sources, using the actual Swift phone core, Go relay and Go
receiver. No overlays or substitute phone implementation were used. Only the
CLI fixture's biometric key is replaced with a software signer and authorization
counter; the Mac substitute owns a dummy login. Production baseline: local main
`36c6ad6`; fixture correction: `594e7c2`.

The first run exposed a fixture assumption: after reconnect, the Mac work stream
may replay an earlier request before a newly created one. The fixture now selects
the exact lease it requested. The full run then passed without changing the
production phone, relay or receiver.

The fixture never creates a phone vault or imports a password. Its Mac
substitute holds a dummy example.com login.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift build --package-path AgentKeyringPackage \
  --product agent-keyring-phone-fixture
devenv shell -- go build -o /tmp/keyring-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-relay-fixture ./script/relay_fixture
/tmp/keyring-relay-fixture --mode phone --relay /tmp/keyring-relay \
  --phone-binary "$PWD/AgentKeyringPackage/.build/debug/agent-keyring-phone-fixture"
```

Passed:

- Normal hostname resolution refuses a non-tailnet peer before sending a
  request. The explicit loopback proof override then permits this fixture.
- Swift and Go compute the same full pairing comparison. Restart during
  pairing verifies the saved comparison and Mac-signed PHONE addition.
- Only escalated requests reach the phone. Reopening fetches pending work
  without any import, and the existing receiver does not enrol again.
- A proxy discards the acknowledgement after the Mac independently receives
  the exact signed phone answer. Both relay and phone restart; the identical
  answer is acknowledged with the authorization counter still at one.
  The phone waits for the Mac instead of showing premature approval.
- The Mac substitute commits delivery under that answer. The real Go receiver
  advances its previously pinned key set, verifies both signatures and opens
  the dummy login. The phone displays the actual approval. End Access prevents
  another delivery.
- Plain Deny needs no authorization; a typed reply adds one signature and
  remains visible while waiting. Close the phone after its answer is
  acknowledged; a Mac denial committed while it is closed arrives on reopening,
  with the reply intact and no second authorization. Scoped clear then works.
- A local request needs no remote receiver enrolment. Its approval uses one
  authorization; End remains active until the Mac reports REVOKED.
- After accepting a higher configuration revision, the phone and relay restart
  with the relay's isolated fixture state replaced in turn by an older valid
  configuration, changed bytes at the same revision, a PHONE-signed
  configuration and an invalid rule-owner signature. Each is refused for the
  expected reason before the authorization counter advances. Restoring the
  highest valid configuration recovers the normal denial flow. The cached
  original configuration stays at the lower revision; the advance is published
  directly, so this checks a real downgrade.

The earlier approval-only run exposed and fixed a relay race: a phone that had seen PendingRequest
could miss its terminal Lease if the outcome arrived before the initial lease
snapshot. A fresh stream could also omit a denial committed while the phone
was closed. The relay now replays the latest state of each escalation on open
and sends each subsequent change, including terminal outcomes.

The Swift phone fixture and a fresh iOS Simulator SDK app build passed on
the mini after cleanup. The resulting app embeds no extensions; its notification
environment resolves to development. No unit tests ran and no simulator windows
opened. Logs are preserved in the main checkout's
`.private/proofs/r4-phone-configuration/`: `phone-configuration-joint.log`,
`phone-configuration-swift-build.log` and `phone-configuration-main-ios.log`.
The initial fixture failure is retained as `phone-configuration-joint-main-failure.log`.

## Device status

No new build was installed: the orchestrator explicitly holds installation
until the contract simplification lands. Build 7 remains on Josh's iPhone, per
the orchestrator's installation report. No certificate or Apple account change
was made.

After the hold is lifted, an agent should build and install with existing
signing, then help Josh check one dummy request: pair by comparison and Mac
Touch ID, approve over mobile data with one Face ID, and repeat with a network
cut just after Face ID. Restoring the connection must deliver the same answer
without another Face ID. Deny with a typed reply must reach the agent. These
physical checks, production Mac delivery, and an Apple notification remain
unproved here; the joint fixture is not a substitute for them.
