---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: reviewed; transport/storage can build; pairing and Automatic contracts need completion below
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
requests need the MacBook awake and connected. Release 4 (RFC 0006) adds the
iPhone, so requests can be answered with the MacBook shut.

Not in this RFC: website sessions (they belong to the agent's browser), hosted
agents that cannot run a client or reach the tailnet, and any change to where
the MacBook keeps its copy of the passwords.

## Roles

| Role | Runs on | Holds | Does |
| --- | --- | --- | --- |
| Relay | Mac mini, `agent-keyring-relay`, Go | Lease records, operation records, enrolment records, sealed bundles, signed login index | Accepts requests, wakes approvers, stores decisions, hands sealed bundles to receivers |
| Approver | MacBook (Mac app); iPhone from release 4 | The passwords, the rules, its signing key, the receiver keys it has approved | Decides, seals approved logins to the receiver, signs the decision |
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
  six-digit code on the new machine with the code on the approver and approves
  with Touch ID. Enrolling grants the right to ask, nothing more. Limit: any
  agent running on an enrolled machine can ask as that machine.
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

The MacBook's copy keeps today's protections and limits in this release. RFC
0006 covers moving the strong copy to the iPhone.
The mini may also run an enrolled receiver. A login approved to that receiver
is readable on the mini; the relay's ciphertext-only role does not conceal it
from software administering that same machine.

## How a remote sign-in works

1. **Enrol (once per machine).** `agent-keyring enrol --name "build server"`
   generates a TLS key and a P-256 receiver key, connects to the relay, and
   shows a code. The approver shows the same code with the machine name and the
   tailnet node the relay observed. Josh approves with Touch ID and chooses
   whether this machine may use Automatic logins (default off). The client pins
   the approver keys it receives.
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
   by the signature, using the SHA-256 of their UTF-8 bytes.
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
  the enrolment code covers the relay key, the client TLS key and the receiver
  key, so a substituted key changes the code.
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

### Contract work required before the affected slices are complete

- **Pairing (R3.2, R3.4).** Specify the initial TLS exception for unknown peers:
  only Enrol/first PairApprover are available, no credential or approver methods.
  Specify the transcript from which both devices independently derive the code,
  including relay, client TLS/receiver keys and the approver keys being pinned.
  A code supplied by the relay is not itself evidence of a match. Specify the
  authenticated confirmation that commits first-approver pairing after Touch ID;
  the current PairApprover request has no such confirmation. Approver TLS keys
  now have an explicit field alongside their signing keys.
- **Automatic (R3.4 and R4.6).** The current biometric-only signing key cannot
  sign unattended approvals, index updates or background publications. Define
  which operations use a noninteractive key, what the human-authorized key binds
  it to, and how receivers distinguish that authority from Ask approval. In
  release 4 the relay must have explicit authority to sign only published
  Automatic logins; it cannot become a general approver. Also specify the relay's
  encryption key and the exact signed bytes of AutomaticSet (its current
  signature field has no defined payload). Do not disable biometric checks to
  make the existing design work. This is an engineering gap, not a new question
  for Josh.
- **Approver changes (R4.5).** Define how an offline receiver obtains intervening
  signed key sets when the latest signer was not in its pinned set, and how the
  new phone receives current enrolments including revocations rather than a
  replayable bag of old approvals. This needs an agreed pairing/transfer contract
  before enabling additional approvers, not a general consensus service.

The lease store, wire framing, bundle sealing/opening and screens can be built
against the fixed interfaces now. These gaps block claiming a complete enrolment
or unattended approval path, not independent development of those components.

| Slice | Owner | What | Done when |
| --- | --- | --- | --- |
| R3.1 | Terra or Sol | Relay core in Go: SQLite store, lease and operation records, request joining and deadlines from RFC 0004, `RelayWireRequest` server over TLS with pinned keys | A scripted client and a scripted approver complete request, approve, begin, finish, release over loopback TLS; relay restart mid-lease loses nothing |
| R3.2 | Terra or Sol | Enrolment: `Enrol` stream, code derivation, Tailscale node lookup, approver decision, revocation | A Linux test machine enrols, is refused from a different tailnet node with the same keys, and is revoked |
| R3.3 | Terra or Sol | Client: relay transport, enrolled-key storage (file with owner-only permissions on Linux; Keychain on macOS), pinned approver keys, bundle verification and opening | Wrong recipient, wrong lease, expired deadline, unknown signer and tampered ciphertext are each refused with a clear error |
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
