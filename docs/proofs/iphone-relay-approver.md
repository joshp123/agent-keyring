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

The integrated one-configuration flow passed again on the physical Mac mini
from published main `6e09b58e2a5e089169fc7895f6f4888273214756`, including the
Mac lane's shared Swift changes and the designer's phone changes. It uses the
actual Swift phone core, Go relay and Go receiver. No overlays or substitute
phone implementation were used. Only the CLI fixture's biometric key is
replaced with a software signer and authorization counter; the Mac substitute
owns a dummy login. No source fixes were needed for this rerun.

The earlier run exposed a fixture assumption: after reconnect, the Mac work stream
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

The latest Swift phone fixture build and full joint proof passed on the mini
over SSH, without accessing its display. Logs are preserved in the main
checkout's `.private/proofs/r4-phone-build8/`: `phone-build8-joint.log` and
`phone-build8-swift-build.log`. The earlier simulator build and fixture failure
remain under `.private/proofs/r4-phone-configuration/`.

## Device status

Version **0.4.0, build 8** was built in Release configuration from that exact
published source, using command-line version overrides. It was installed on
Josh's physical iPhone after CoreDevice reported it available. A fresh
CoreDevice app inventory confirms version 0.4.0 and bundle version 8. The app
was not launched and no phone settings were changed.

Signing used the existing Apple Development identity and existing development
profile, without provisioning-update or device-registration flags. The saved
bundle passes strict signature verification, embeds no extensions, and has only
the application/team identifiers, development APNs and development debugging
entitlements. Its APNs registration setting also resolves to development.
No certificate, key or Apple account change was made. The signed app is kept
next to build 7 at `.private/builds/phone-0.4.0-8/AgentKeyringPhone.app` in the
main checkout.

The same proof directory contains `phone-build8-device-build.log`, the full
`phone-build8-xcodebuild.log`, `phone-build8-signed-bundle.json`,
`phone-build8-install.log` and `phone-build8-installed-app.json`. Two preliminary
build refusals are retained there: Xcode rejected manually selecting its
managed profile, then rejected a certificate fingerprint with automatic
signing. The successful build used automatic signing with the existing Apple
Development identity and no permission to update provisioning.

The next device check uses one dummy request: pair by comparison and Mac
Touch ID, approve over mobile data with one Face ID, and repeat with a network
cut just after Face ID. Restoring the connection must deliver the same answer
without another Face ID. Deny with a typed reply must reach the agent. These
physical checks, production Mac delivery, and an Apple notification remain
unproved here; the joint fixture is not a substitute for them.
