---
written_by: AI (gpt-6.1-sol, 2026-10-31)
---

# Mac relay approver

`MirrorAppModel.relayApprover` owns the release 3 relay connection. It is an
observable main-actor `RelayApprover`. It starts when the app loads, if already
paired; no setup or biometric prompt appears merely because the app started.
U4 provides the views. Local leases and remote requests use the same wire
contract, with separate authority stores.

## Screen interface

Read `update` or subscribe to `changes()` (current snapshot first). A snapshot
contains connection state, the first-setup comparison, pending enrolments,
remote requests and history, enrolled machines, queued command count,
`needsPublication`, and an error message. Metadata comes from the Mac's mirror
and its enrolled-machine records. Request reason and agent label are claims.
The ID of a remote request is the hex digest of its exact request bytes; it is
not the lease ID. `answerIsQueued` means a prepared answer is in the outbox.
`leases` is the remote in-use/history list: `RelayRemoteLease` has the lease,
local login title/account, enrolled machine, and `endIsQueued`. Filter on
`lease.state == .active` for in use. WatchWork lease reports also cover an
approval made by another device while this Mac was offline. Reports update
display state and close answered prompts; they never authorize a delivery.

- `beginPairing(RelayEndpoint)` observes the relay's TLS key during first setup.
  The endpoint requires a Tailscale address/name. Loopback is an explicit proof
  option. The Mac refuses first setup if the relay already has an approver.
- `confirmPairing(comparedFingerprint:context:)` requires the full eight groups,
  compared with the relay's log. It signs and queues both the confirmation and
  initial key set. An identical retry reuses the saved answer.
- `abandonPairing()` cancels an unconfirmed first setup, including an in-flight
  connection, and durably clears its comparison. The app returns to unpaired
  and can start setup again. A confirmation already signed and queued cannot
  be abandoned, since the relay may already have accepted it.
- `approveEnrolment(id,comparedFingerprint:automaticAllowed:context:)` compares
  the fingerprint with the receiving machine, defaults Automatic permission to
  false, and signs enrolment plus the complete roster, index and Automatic
  grant under that one authorization. `denyEnrolment(id,context:)` signs the
  enrolment denial. `revokeMachine(recipientID,context:)` removes the machine
  locally and publishes a signed roster omitting it.
- `pendingApproverPairings` / `update.approverPairings` contains new approving
  devices, with locally computed fingerprints and queued-answer status.
  `confirmApproverPairing(id,comparedFingerprint:context:)` compares with that
  device, authorizes once, and queues the next signed key set. It binds the
  exact current signed machine roster and pairing transcript, preserves the
  rule owner, and changes local `approverKeySet` only after acknowledgement.
  The snapshot exposes the resulting signed key set. A pending relay message
  alone adds no key. This is the Mac half of pairing the iPhone in release 4.
  `dismissApproverPairing(id)` durably dismisses a comparison that does not
  match. That pairing ID stays hidden across reconnects and restarts. It sends
  no relay request; cancel the comparison on the phone too. A pairing already
  confirmed and queued for delivery cannot be dismissed.
- `approve(id,context:)` signs and seals one task's login after checking the
  current local rules and machine keys. An already prepared answer is resent
  without another authorization. `deny(id,reply:context:)` sends a plain denial
  without Touch ID. A nonempty reply needs one human signature.
- `clearDenial(loginID:recipientID:)` clears the local hold-off and queues the
  relay's unsigned `ClearDenial` on the pinned connection. Denied history rows
  update too. The method is async because it attempts delivery immediately.
- `revokeLease(leaseID)` records Josh's End as Revoked locally, then queues
  `RevokeLease` on the pinned connection. It needs no Touch ID, survives an
  offline restart, and keeps `endIsQueued` set until acknowledged. It stops
  further relay deliveries; an already opened password cannot be recalled.
- `publishCurrentRules(context:)` signs the current index, Automatic grant and
  roster under one authorization. An import or rule change sets
  `needsPublication`; local changes take effect before publication. A stale
  grant cannot authorize a new Mac delivery. U4 asks for publication while Josh
  is present, rather than prompting from a background callback.
- `start()`, `stop()` and `reconnect()` manage transport without discarding
  pending work, prepared answers or deadlines.

Each authorization accepts the panel's own `LAContext`. Cancellation invalidates
that context and leaves the request pending. Plain Deny can proceed while an
Approve task is cancelled. Only one human authorization runs in this backend
at once. The screens should cancel their approval task before closing it or
sending a denial.

## Authority and delivery

The human signing key is a Secure Enclave P-256 key requiring biometrics. The
Automatic signing key is a separate enclave key without a biometric flag,
usable while unlocked. Key handles and the TLS private identity use app-only,
non-synchronizable data-protection Keychain items. None syncs to iCloud.

Paired pins, exact request bytes, enrolled receiving keys, publication revisions,
denial hold-offs and prepared commands live in `relay-approver` beside the access
rules. `LeasePersistence` commits them against the app-private Keychain digest,
with the same edit and rollback refusal as the local lease authority. Secret
values and TOTP seeds are absent from these snapshots; the outbox contains only
the sealed delivery and signed bytes. Source policies must have passed the
existing signed-rule check before an approval or publication.

An approval commits its exact signed decision and HPKE bundle before network
I/O. The outbox retries those bytes until the relay acknowledges or reports a
terminal conflict. It never signs again, reseals, resets the clock or prompts
on retry. A local rule or machine revocation removes undelivered approvals.
Already opened credentials cannot be recalled.

The Swift byte helpers implement `internal/relaycrypto`'s transcript and digest
formats. TLS uses one method per connection, four-byte big-endian protobuf
framing, TLS 1.3, client identity and the paired relay SPKI. Uploads use
`SignedDecision.bundle`. Precomputed TOTP steps end at the signed 30-minute
maximum; the seed stays on the Mac. The client must continue checking the exact
request scope, signature, grant revision and signed deadline before opening.

Actual Touch ID, embedded-context signature reuse, Watch approval, and enclave
refusal while locked remain Josh's device checks. The process proof substitutes
only dummy credentials and a software signer; it exercises production transport,
HPKE, state, decisions and outbox.

Reproduction and observed results are in
[the system proof](../proofs/mac-relay-approver.md).
