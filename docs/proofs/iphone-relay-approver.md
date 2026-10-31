Written by AI on 2026.10.31 by model gpt-6.1-sol.

# iPhone relay approver: R4.3 and phone half of R4.5

The real `PhoneImportBackend` composes `PhoneRelayApprover` with the R4.2 vault,
Secure Enclave keys and device-only TLS identity. The existing home, request and
settings views consume its snapshots. No view was changed for this backend.
The Mac remains the rule owner and signs the phone's addition. No live authority
was paired or changed during this work.

## Pairing screen interface

These types are in `AgentKeyringApprovalUI`:

```swift
public struct PhoneRelayEndpoint: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16)
}

public enum PhonePairingState: Hashable, Sendable {
    case notPaired
    case connecting
    case comparing(fingerprint: String, relayAddress: String)
    case paired
    case failed(String)
}

// PhoneKeyringBackend
func beginPairing(endpoint: PhoneRelayEndpoint) async throws
func cancelPairing()

// PhoneKeyringModel: views call these.
public func beginPairing(endpoint: PhoneRelayEndpoint) async
public func cancelPairing()
public private(set) var pairing: PhonePairingState
```

`PhoneKeyringSnapshot.pairing` has the same type, defaulting to `.notPaired`.
`PhoneSettings.rulesUpdatedAt: Date?` is the last verified owner-index receipt
time; it defaults to nil. It is suitable for “Rules checked …” copy.
The service connection and requests are real snapshot values as well.

The fingerprint is computed locally over the exact transcript bytes. The phone
does not offer first-authority bootstrap. It activates only after verifying a
previous approver's signature, the compared transcript, its own signing/TLS
keys, the unchanged rule owner, and the exact signed roster revision/hash bound
by the Mac. A saved comparison survives interruption. Foregrounding resumes an unfinished
attempt automatically; explicitly cancelling disables that resume. Reopening pairing can
verify an already accepted addition from that receipt; an APPROVED flag alone
cannot establish trust. Cancel closes the attempt and does not activate it.

## Approval and recovery

A completed import reconnects so requests previously missing a local login are
replayed. Each foreground connection walks the signed approver chain, verifies the signed
machine roster, fetches the owner's index through GetIndex, and opens WatchWork.
WatchWork replays pending requests and active remote leases before updates.
The phone uses its own login metadata and the signed roster's receiver keys.
Blocked, unmatched, ambiguous and Automatic logins cannot use the human Ask
approval path. The index retains Mac login IDs and the vault's conservative
source/fallback matching from R4.2.

Approve checks the request and current index before Face ID. One fresh
`LAContext` evaluates biometrics, opens the enclave-protected vault item and
signs the decision. Key operations cannot silently request a second prompt:
after authorization the context forbids interaction. Actual reuse across the
two enclave operations remains a physical-device proof.

The phone seals username/password and timed codes to the enrolled receiver
with CryptoKit HPKE. The signed decision binds the original request digest,
recipient, receiver key, lease, deadline, reply and ciphertext. No network call
occurs between successful authorization and the atomic outbox commit. Retrying
and process restart reuse the saved statement, signature and ciphertext. An
accepted resend reporting an already terminal lease does not reactivate it.

Plain Deny has no signature and no biometric operation; it travels over the
pinned approver connection with APPROVER_CONNECTION authority. A denial with
a reply uses the explicit action's Face ID signature. ClearDenial is scoped to
recipient/login. End Access calls RevokeLease over the pinned connection and
reports an end only after the relay confirms a terminal lease. Lease updates
drive the in-use list, including approvals made on another approver.

State and outbox files use complete iOS file protection and are excluded from
backup. TLS private material is in explicitly non-synchronizable,
WhenUnlockedThisDeviceOnly Keychain items. The production app has no software
replacement for the enclave/Face ID keys. Stage logs contain counts and error
domain/code, never passwords, code seeds, replies or login metadata.

## System proof on the Mac mini

The fixture invokes the production phone core, vault, TLS, HPKE, signature and
outbox code against the real Go relay and receiver wire methods. Its software
keys, authorization counter and dummy Passwords input are confined to the CLI
fixture target; they are not compiled into the iPhone app.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift build --package-path AgentKeyringPackage \
  --product agent-keyring-phone-fixture
devenv shell -- go build -o /tmp/keyring-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-relay-fixture ./script/relay_fixture
/tmp/keyring-relay-fixture --mode phone --relay /tmp/keyring-relay \
  --phone-binary "$PWD/AgentKeyringPackage/.build/debug/agent-keyring-phone-fixture"
```

Passed on the physical Darwin Mac mini with Xcode beta:

- Swift and Go computed the same full pairing fingerprint. The phone closed
  before the Mac signed, then verified the accepted addition after reopening.
- The phone adopted the already enrolled receiver through the signed roster.
  The receiver did not enrol again.
- A pending request survived phone-process restart and backlog replay.
- A TCP fault discarded the encrypted acknowledgement after the relay committed
  ACTIVE; the independent receiver observed that commit. Both relay and phone
  restarted. The saved answer was acknowledged with the authorization counter
  still at one.
- Go verified the phone signature and opened CryptoKit HPKE contents: expected
  dummy username/password, Mac login ID, lease ID and at least 60 timed codes.
- Phone End Access was confirmed, repeating it was harmless, and subsequent
  receiver delivery was refused. An already active Mac approval, created while
  the phone was disconnected, appeared on reconnect and was ended from the
  phone without another authorization.
- Plain Deny used zero authorizations and carried no signed denial proof.
  Deny with a reply added one authorization and a verified signed reply.
  ClearDenial allowed a fresh task to ask again.

The final run's isolated state directory and output are recorded in
`.private/proofs/r43/phone-relay-proof.log` in the main checkout. Build output
is alongside it. No unit tests ran. No simulator windows opened on the MacBook.
These checks prove the protocol/storage/recovery path with fixtures, not Apple
credential exchange, Secure Enclave enforcement, Face ID, mobile data or a real
website sign-in.

## Remaining device checks

The pairing views are the designer's work. The Mac's added-approver action,
physical fingerprint comparison and Touch ID are the Mac lane's work.
APNs and delay registration remain R4.4; the R3 relay returns unavailable for
RegisterPush. The phone's custom microphone button still needs a speech backend;
typed replies and keyboard/system dictation use the real signed-reply path.

Josh's morning check, with an agent handling relay/receiver commands:

1. Unlock the iPhone and open Agent Keyring. If needed, tap Allow Exports.
   In Passwords, export two harmless test logins to Agent Keyring. Reopen the
   app and check the saved count remains.
2. Change one test password in Passwords and export only that login. The date
   advances and the count stays the same. This count alone does not prove the
   changed secret; the approval below must open and use it.
3. Start pairing to the agent-provided tailnet endpoint. Compare all eight
   fingerprint groups on phone and Mac. Approve the addition on the Mac with
   Touch ID. The phone should become paired without enrolling the receiver again.
4. Have an agent request the test login. With Wi-Fi off and Tailscale connected
   over mobile data, open the request and approve. One Face ID should both open
   and sign; the receiver should sign in using the changed test password.
5. For another request, approve and interrupt the network immediately after
   Face ID. Restore it and reopen the app if necessary. The same answer must
   arrive without another Face ID.
6. Deny a fresh request with a harmless reply. The receiver must see that reply
   with one Face ID. Plain Deny must need none. Check End Access stops a later
   receiver operation, and that Mac Touch ID approval still works.

No production authority is activated automatically. Automatic publishing,
push and Josh's cutover choices remain their later slices.
