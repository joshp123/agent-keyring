---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: agreed by Opus and Astra for implementation, with round 10 contract completions; device proofs pending
depends_on: 0004
related: 0006 (iPhone approver), 0007 (approval UI); docs/rfc/README.md has the build plan
---

# RFC 0005: requests from other machines

## What ships

Agents on other machines, such as the Mac mini, Linux servers or a cloud VM
that can join the tailnet, use the same `agent-keyring` commands as agents on
the MacBook. Their requests go to an always-on relay on the Mac mini. The
MacBook answers them, by rule or with Touch ID, and seals the approved login to
the receiving machine. The relay stores and forwards; it cannot open what it
forwards for Ask and Blocked logins.

This is release 3. Its limit, stated plainly: Ask requests and Automatic
requests need the MacBook awake and connected. Release 4 (RFC 0006) lets Josh
answer on his iPhone when he is away from the keyboard; the MacBook still
delivers, so it still needs to be awake.

Not in this RFC: website sessions (they belong to the agent's browser), hosted
agents that cannot run a client or reach the tailnet, and any change to where
the MacBook keeps its copy of the passwords.

## Roles

| Role | Runs on | Holds | Does |
| --- | --- | --- | --- |
| Relay | Mac mini, `agent-keyring-relay`, Go | Lease records, operation records, enrolment records, sealed bundles, signed login index | Accepts requests, wakes approvers, stores decisions, hands sealed bundles to receivers |
| Approver | MacBook (Mac app); from release 4 the iPhone signs answers that the MacBook delivers | The passwords, the rules, its signing key, the receiver keys it has approved | Decides, seals approved logins to the receiver, signs the decision |
| Receiver | The agent's machine, the Go `agent-keyring` client | Its TLS key, its receiver key, the approver keys it pinned | Requests, opens bundles, fills, runs programs, reports outcomes |

The agent-facing contract does not change: `find`, `lease`, `status`,
`release`, `fill`, `exec`, `read`, same flags, same exit codes. The client
uses the local socket when the Mac app is on the same machine and the relay
otherwise.

## Protections and their limits

- **The relay never sees Ask or Blocked passwords.** The approver seals each
  approved login to the public key of the receiver it approved at enrolment.
  The relay could keep sealed bundles; it cannot open them. Limit: whoever
  controls the relay can read login names and accounts, delay or drop
  requests, and refuse service.
- **Only approved machines can ask.** A machine enrols once; Josh compares a
  key fingerprint on the new machine with the one on the approver and approves
  with Touch ID. Enrolling grants the right to ask, nothing more. Limit: any
  agent running on an enrolled machine can ask as that machine. Its keys are
  an owner-only file, so that includes any process running as its user.
- **A receiver opens only what an approver signed for it.** It checks the
  decision against the approver keys it pinned at enrolment, and that the
  decision names it, this lease and an unexpired deadline. Limit: a receiver
  that has opened a password can keep it. A lease bounds new deliveries, not
  copies.
- **Deadlines are set by the approver.** `not_after` is in the signed decision
  and is at most 30 minutes after approval. Reconnects, relay restarts and
  retries never extend it. One-time codes in a bundle are precomputed for each
  time step up to that deadline, so the code seed stays with the approver and
  later codes do not exist on the receiver.
- **The tailnet is the only path.** The relay listens on its tailnet address
  only. Tailnet access rules allow the relay port from enrolled machines and
  approvers. Every connection also needs mutual TLS with pinned keys, and the
  relay checks with Tailscale that the connecting node is the node the client
  enrolled from. Limit: the tailnet's own administration is trusted for
  reachability, not for authorisation.
- **No public credential endpoint exists.** The only outbound public traffic
  is the Apple push in release 4, which carries no secret.

The MacBook's copy keeps today's protections and limits. Release 4 keeps the
passwords on the MacBook; RFC 0006 describes a later, optional copy on the
iPhone for answering with the MacBook shut.
The mini may also run an enrolled receiver. A login approved to that receiver
is readable on the mini; the relay's ciphertext-only role does not conceal it
from software administering that same machine.

## How a remote sign-in works

1. **Enrol (once per machine).** `agent-keyring enrol --name "build server"`
   generates a TLS key and a P-256 receiver key, connects to the relay, and
   shows a code. The approver shows the same code with the machine name and the
   tailnet node the relay observed. Josh approves with Touch ID and chooses
   whether this machine may use Automatic logins (default off). The client pins
   the approver key set bound into that code, after checking the signed
   enrolment decision. An APPROVED status from the relay alone is insufficient.
2. **Request.** The agent runs `agent-keyring lease` as on the MacBook. The
   relay refuses Blocked logins from the signed index without waking anyone,
   otherwise stores a `RequestRecord` and sends it to connected approvers.
3. **Decide.** The approver parses the record, then checks the login and the
   recipient against its own data, never the relay's. Automatic, with this
   machine allowed: it approves without prompting. Ask: the approval panel
   (RFC 0007). Blocked: deny.
4. **Seal.** On approval the approver builds `BundleContents` (username,
   password, codes up to `not_after`, saved sites), seals it to that
   receiver's enrolled key, and signs a `DecisionStatement` that binds the
   request digest, recipient, lease, deadline and ciphertext hash. `Decide`
   uploads that decision with `SignedDecision.bundle`. The relay durably stores
   the bundle, original request bytes and decision with the lease transition
   in one transaction before acknowledging it. Denial replies are also bound
   by the signature, using the SHA-256 of their UTF-8 bytes. A denial without
   a reply is the exception: the approver sends it unsigned over its pinned
   connection, with authority `APPROVER_CONNECTION`, so Deny needs no Touch ID.
   It grants nothing, and a relay that wanted to stop a request could withhold
   it anyway. A denial with a reply is signed with the human key, because the
   reply is an instruction to the agent; a receiver shows a reply only when
   that signature checks. The relay returns that signed denial and the exact
   request bytes in `Lease.signed_denial`, with no bundle, and the receiver
   verifies them the same way as an approval.
   Josh's "let it ask again" sends `ClearDenial` over the same pinned
   connection, unsigned for the same reason: it lets a machine ask, and each
   new request still needs its own decision.
   Approvers see remote leases as `ApproverWork.lease` updates on the same
   stream, and Josh ends one early with `RevokeLease`, also unsigned over the
   pinned connection: it only takes access away.
5. **Fill.** The receiver's `BeginOperation` records the operation at the relay
   and returns the `SealedDelivery`, including the exact approved request bytes.
   The receiver checks their digest and scope against the request it retained
   locally for this lease: login, task, recipient, purpose and program. It checks
   the signed deadline and ciphertext hash, then checks the opened bundle's
   login, lease and deadline against that decision. Fill uses only the bundle's
   saved sites. It submits, clears, drops the values and reports the outcome.
   The receiver keeps the expected request fields with its local lease reference
   so a new CLI process can make the same checks; it never accepts a new scope
   just because the relay returned it.

Operation records, retries and Uncertain outcomes work exactly as in RFC 0004,
with the relay holding the records instead of the Mac app.

## Availability and recovery

| Event | Behaviour |
| --- | --- |
| MacBook asleep or offline | New requests wait, then end as Unanswered at their pending deadline. Active leases keep working, because their bundles are already at the relay |
| Relay restarts | Nothing is lost: leases, operations and bundles are on disk. Clients reconnect and rejoin by lease ID without a new prompt |
| Approver answers but the acknowledgement is lost | It resends the same signed decision and bundle. The relay acknowledges an exact accepted resend even after the pending deadline; a conflicting answer returns the current lease state, not an invitation to approve again |
| Client disconnects while waiting | The request stays. `status --wait` rejoins it |
| Mini down or home internet down | Remote agents get "Agent Keyring unreachable". Local agents on the MacBook keep working through the local socket |
| Machine revoked | The approver stops sealing to it and the relay ends its leases. Bundles it already opened are not recalled |

A home outage stops remote requests. That is the limit of one always-on host.

## Wire and storage

- Messages: `relay.proto` and `bundle.proto`, with the client methods from
  `agentkeyring.proto` unchanged inside `RelayWireRequest`.
- Framing: the RFC 0004 length-prefixed frames inside TLS 1.3. One method per
  connection; `WatchWork` and `WatchLease` stream.
- Keys: TLS keys are self-signed and pinned by SPKI hash on both sides. The
  relay key is pinned by the approver at its setup and by clients at enrolment;
  the enrolment code covers the relay key, the client TLS key, the receiver
  key and the approver key set the client will trust. A substituted key changes
  the code.
- Signatures: ECDSA P-256 over the exact serialized statement bytes. Nobody
  re-serializes to compare.
- Sealing: HPKE base mode, DHKEM(P-256), HKDF-SHA256, AES-256-GCM. Go must use
  a maintained HPKE implementation: the standard library's if the pinned Go
  version has it, otherwise Cloudflare's CIRCL. The MacBook and iPhone use
  CryptoKit.
- Relay storage: one SQLite database in the relay's state directory. No
  passwords are stored there in this release.
- Deployment: the relay is declared in nix-darwin as a LaunchDaemon on the
  mini, so it starts after power loss without a login. Agents may deploy and
  restart it like any other service; that cannot widen access to Ask or
  Blocked logins, because the relay holds nothing that opens them.

## Migration

- Existing local agents on the MacBook keep the local socket. Nothing changes
  for them.
- The relay starts empty. Josh pairs the MacBook with it once (`PairApprover`:
  the relay logs a code, the Mac app shows the same code, Touch ID), then
  enrols each remote machine. Limit: whoever controls the mini at that moment
  could pair a different approver first. That approver holds no passwords, and
  the MacBook would refuse to pair with a relay that already has one, so the
  mistake is visible rather than silent.
- The approver key on the MacBook is new: a Secure Enclave P-256 signing key
  created by the Mac app. Its access control requires biometrics; whether an
  Apple Watch tap can satisfy the same key needs the device proof below.
- The Mac app publishes a signed login index to the relay after each import or
  rule change.

## Build slices

### Settled contracts (round 10)

These close the three gaps Astra found. Messages are in `relay.proto` and
`bundle.proto`; all additions are compatible.

**Pairing.**

- *Unknown peers.* A TLS connection from a key the relay has not pinned may
  call only `Enrol` or `PairApprover`; `ConfirmPairing` is also available while
  the relay has no approver. Other methods need a pinned key of the appropriate
  role. Enrolment and pairing keys must match the TLS peer key.
- *Codes.* Each device computes a fingerprint itself from the pairing
  transcript defined in `relay.proto`: the relay's TLS key as that device saw it
  or pinned it, the new party's keys, and the exact current approver key-set
  bytes. The new device gets that candidate set in `EnrolStatus`; the existing
  approver uses its locally pinned set. The relay never supplies the code the
  human compares; `EnrolStatus.code` is display only. Display the first 16
  SHA-256 bytes as uppercase hex in eight groups of four characters and compare
  all groups. Six digits are insufficient when the relay can choose candidate
  keys and search for a matching short hash. This longer comparison is only
  for device setup, not ordinary approvals. An unexpected set change restarts
  the pending comparison.
- *First approver.* `PairApprover` records a pending pairing. The relay prints
  its code in its own log. Josh compares it with the Mac app's code and approves
  with Touch ID; the Mac app then signs a `PairingConfirmation` over the
  transcript hash with its new approver key. Its `initial_key_set` is a signed
  revision 1 containing just that key as rule owner and the same transcript
  hash. The relay commits both together. There is no unsigned bootstrap key
  set. The current-set transcript component is empty for this first pairing.
  First-setup mode refuses a relay that already has an approver; adding to an
  existing setup uses the path below.
- *Machines.* Enrolment works the same way, with the approver's
  `SignedEnrolmentDecision` as the confirmation. The record binds the hash of
  the compared key-set bytes. On APPROVED, `EnrolStatus` returns the exact
  record and signed decision. The client checks its own keys, that key-set
  hash, the approval choice and the signature by a key in the compared set;
  only then does it pin the set and accept recipient ID and Automatic access.
- *Adding an approver.* The phone calls `PairApprover`. Its pending request
  reaches existing approvers through `ApproverWork.pairing`. Both screens
  compute the code from the phone's keys, the pinned relay key and the current
  key-set bytes. After the comparison and Touch ID, the Mac signs the next
  `ApproverKeySet`, with the phone added, the pairing transcript hash and the
  current enrolment-set revision and digest. `PublishApproverKeys` activates
  the phone and completes its pending stream. The phone checks that the new
  set is signed by a key in the compared previous set, advances its revision,
  contains its own keys and matches the transcript. No relay status can add
  an approver by itself. A lost reply can return the same accepted set.
- *Current enrolments.* After every enrolment or revocation the approver
  publishes a `SignedEnrolmentSet`: the full list of enrolled machines, with a
  revision. Revoking means leaving a machine out of the next revision, so an
  old approval cannot bring it back. When an approver pairs a new one (the
  iPhone in release 4), `ApproverKeySet.enrolment_set_revision` and
  `enrolment_set_sha256` name the current set, and the new approver fetches and
  accepts exactly that signed set before answering requests. The Mac publishes
  an empty signed roster too if no machines have enrolled yet.
  `ListEnrolments` remains for display.
- *Approver key changes.* The relay keeps every `SignedApproverKeySet`.
  `GetApproverKeyChain` returns all of them after a given revision, so a
  receiver that was offline walks the chain from a key it pinned, each step
  signed by a key in the previous set.

**Automatic approval.**

Approver keys need Josh's biometric check on every use, so they cannot approve
unattended. Automatic approval therefore uses its own key with narrower
authority, never an approver key with the check turned off.

- The rule owner signs a `SignedAutomaticGrant` while Josh is present (when he
  changes a rule or enrols a machine). It names one Automatic signing key, the
  logins that are Automatic, and the machines allowed them, with a revision.
- An Automatic decision is signed by that key and says
  `authority = AUTOMATIC_RULE` with the grant revision. A receiver opens it only
  if the grant is signed by the current rule owner, names that Automatic key,
  lists both the login and the receiver, and matches the decision's grant
  revision. Receivers fetch `GetAutomaticGrant`, retain the highest valid
  revision and reject a downgrade or different bytes at the same revision.
  An Ask decision says `authority = HUMAN` and must be signed by an approver
  key. Neither can stand in for the other.
- Release 3: the Automatic key lives in the Mac app, in the Secure Enclave
  without a biometric requirement. It is the MacBook's delivery key (role
  MAC_DELIVERY), usable while the Mac is awake, including with the screen
  locked. Release 4 also uses it to deliver logins Josh approved on his iPhone
  (RFC 0006). It never signs a HUMAN decision. Automatic logins still need the
  MacBook awake, as this RFC already says.
- Later, for the MacBook-shut step: the Automatic key and an encryption key
  live on the relay (RFC 0006). The relay can approve only the logins the grant lists, for the
  machines it lists.
- Each new lease is evaluated on its own: Automatic logins are approved again
  without a prompt, as Josh specified.
- Login index updates are signed with the approver key at the moment Josh
  imports or changes a rule, so they need no unattended key.
- `GetIndex` returns the rule owner's signed index for other approvers to
  follow. Index and grant revisions continue increasing across a rule-owner
  change. Receivers learn owner changes through the signed approver key chain.

What still needs the device: whether an Apple Watch tap satisfies the approver
key, and that a Secure Enclave key without a biometric flag signs while the Mac
is unlocked and refuses while it is locked.

The lease store, wire framing, bundle sealing and opening, and screens can be
built now. Pairing and Automatic code follow the contracts above.

| Slice | Owner | What | Done when |
| --- | --- | --- | --- |
| R3.1 | Terra or Sol | Relay core in Go: SQLite store, lease and operation records, request joining and deadlines from RFC 0004, `RelayWireRequest` server over TLS with pinned keys | A scripted client and a scripted approver complete request, approve, begin, finish, release over loopback TLS; relay restart mid-lease loses nothing |
| R3.2 | Terra or Sol | Enrolment: `Enrol` stream, code derivation, Tailscale node lookup, approver decision, revocation | A Linux test machine enrols, is refused from a different tailnet node with the same keys, and is revoked |
| R3.3 | Terra or Sol | Client: relay transport, enrolled-key storage (a file with owner-only permissions, on Linux and on Macs without the app), pinned approver keys, bundle verification and opening | Wrong recipient, wrong lease, expired deadline, unknown signer and tampered ciphertext are each refused with a clear error |
| R3.4 | Sol | Mac app approver: relay connection, `WatchWork`, local decision checks, bundle sealing with precomputed codes, signed decisions, outbox with resend until acknowledged | MacBook approves a remote request; killing the network after Touch ID and restoring it delivers the same decision with no second touch |
| R3.5 | Terra | nix-darwin service and tailnet access rule for the relay port | Mini reboots and the relay is back before anyone logs in |
| R3.6 | Opus | Enrolment and remote-request screens in the Mac panel (RFC 0007) | Josh can tell a remote request from a local one at a glance |

R3.1 and R3.3 can start together against the proto. R3.4 needs R3.1.

## Human proofs for release 3

- **Device: MacBook, Josh present.** Enrol the mini and one Linux machine by
  code. An agent on each completes a real multi-step sign-in in its own browser
  with one Touch ID.
- **Reconnect.** Cut the agent machine's network mid-wait and mid-lease;
  restore it. No second prompt, no extended deadline.
- **MacBook asleep.** A remote request waits, then reports Unanswered. Nothing
  else releases it.
- **Restart.** Restart the relay and the Mac app during an active lease. The
  next fill works without a prompt; a repeated fill returns the recorded result,
  or Uncertain if none was recorded, without another submit.
- **Wrong recipient.** A second enrolled machine cannot open the first
  machine's bundle.
- **Watch.** Whether an Apple Watch tap can approve with the enclave signing
  key. If not, Watch stays a notification and the RFC says so.
