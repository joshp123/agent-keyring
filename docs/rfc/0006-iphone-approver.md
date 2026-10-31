---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: agreed for implementation after Astra's round 15 contract corrections; device proofs pending
depends_on: 0004, 0005
related: 0007 (approval UI); docs/rfc/README.md has the build plan
---

# RFC 0006: approving on the iPhone

## What ships

When Josh is away from the MacBook, in bed or out, an agent's request reaches
his iPhone. He looks at it, approves with Face ID or denies, and the agent
carries on. This works for agents on the MacBook itself and for agents on
other machines.

The MacBook keeps holding the passwords and keeps approving with Touch ID when
Josh is at the keyboard. The iPhone holds no passwords. It signs Josh's answer;
the MacBook checks that signature and delivers the login. So the phone works as
an approval device even if importing passwords onto it never works.

This is release 4. The MacBook must be awake, logged in and able to open its
vault; its screen may be locked. Answering with the MacBook shut needs the phone to hold the
passwords too; that is the later step at the end of this RFC.

## How a request reaches Josh

1. An agent asks for a login. The request reaches the Mac app, from the local
   socket or from the relay (RFC 0005).
2. If Josh is at the MacBook, the approval panel appears and Touch ID answers
   it, as in release 2.
3. If the panel has not been answered after his delay, the Mac asks the iPhone.
   The delay is a Mac setting, 30 seconds to 9 minutes, default 2 minutes. The
   request still expires ten minutes after creation (RFC 0004); escalation
   never resets that deadline. An existing ten-minute delay becomes nine
   minutes, leaving time to answer. Restarting the app does not reset the delay. If
   the Mac's screen is locked, it asks the iPhone at once, because nobody is at
   the keyboard.
4. The relay sends an Apple push: "An agent is asking for a login." No site,
   account or password is in the push.
5. Josh taps it. The app opens and shows the request: site and account, the
   agent and machine, the purpose and the 30-minute limit, and the agent's
   reason marked as its claim.
6. **Approve** asks for Face ID, then the phone signs its answer with a key in
   its Secure Enclave and sends it to the relay. **Deny** sends at once without
   Face ID. **Deny with a reply** needs Face ID to authenticate the instruction
   sent to the agent; the ordinary keyboard handles text and dictation.
7. The relay passes the answer to the MacBook. The MacBook checks it was
   signed by the paired phone for this exact request, then delivers: to a
   local agent directly, or sealed to a remote machine as in RFC 0005.
8. The first committed lease decision wins: in the local Mac store for local
   requests, at the relay for remote requests. A phone answer received by the
   relay is not yet a completed approval. The phone says "Waiting for your Mac"
   until that authority commits the result. The other screen then shows
   "Answered on your Mac" or "Answered on your iPhone".

If the phone's answer is sent but not acknowledged, it is resent from an
outbox until the relay confirms. Josh never touches Face ID twice for one
answer.

## Why this shape

- Josh's words: if loading passwords onto the phone fails, it should still work
  as approval for when he is away. Here the phone needs no passwords at all.
- Touch ID at the keyboard stays exactly as it is. There is no choice to make
  about where the main copy lives for this release: it stays on the MacBook.
- One channel to the phone: the relay on the tailnet plus a standard Apple
  push. Josh said on 14 Oct that normal apps with push notifications need
  neither iCloud nor a local Mac, so the old iCloud channel in the October code
  is removed rather than kept alongside. The same channel carries the later
  MacBook-shut step.

**Why direct Apple push, despite the existing CloudKit entitlement.** CloudKit
can send a visible subscription notification without our own APNs signing key.
It could carry just an opaque wake-up hint while the Mac is available. But an
entitlement is not a deployed, working channel: the devices need the same
iCloud account and environment, a production schema and a saved subscription.
Our old channel has no recorded production proof. Direct APNs needs one key
setup, then the mini can notify independently of iCloud and the MacBook. Keep
that choice rather than add a temporary second channel merely to avoid the
setup. The key blocks the physical notification proof, not building and proving
the signed-answer flow. Sources: Apple's [CloudKit subscriptions](https://developer.apple.com/documentation/cloudkit/ckquerysubscription),
[schema deployment](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
and [APNs signing keys](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).

## What each device holds

| Device | Holds | Keys |
| --- | --- | --- |
| MacBook | The passwords and rules, as today | Touch ID approver key (role MAC); delivery key with no biometric check (role MAC_DELIVERY), the same key RFC 0005 uses for Automatic logins |
| iPhone | No passwords | Approver signing key in the Secure Enclave, Face ID on every use (role PHONE); TLS key for the relay |
| Mac mini | Requests and answers in transit, sealed logins for remote machines | Relay keys (RFC 0005) |

The phone's existing signing key was created without a Face ID requirement.
It is replaced, not reused.

## Protections and their limits

- **Josh authenticates each phone approval.** The phone's key needs Face ID
  for every signature. Limit: if Josh approves a request he should not have,
  that machine gets that login for up to 30 minutes, and can keep what it
  received.
- **The MacBook delivers only what the phone signed.** It checks the phone
  key, the request digest, the choice and the deadline. Remote machines check
  the phone's signature too, so the delivery key cannot pass off its own
  decision as Josh's. Limit: software in control of the MacBook can already
  read the MacBook's copy, so these checks do not protect against that; they
  stop the relay and anything else from approving.
- **The push carries nothing private.** The phone fetches the request over the
  tailnet with mutual TLS. Limit: Apple and the relay can delay or drop a push;
  opening the app always shows every waiting request.
- **Approvals travel only over Josh's tailnet.** Passwords never go to the
  phone in this release.

## Pairing and losing the phone

**Pairing (once).** In the phone app, Josh chooses Pair. The phone sends its
keys to the relay; the Mac app shows the request. Both screens show a code that
each device computes itself (RFC 0005, "Pairing"). Josh compares them and
touches Touch ID. The MacBook signs a new approver key set that includes the
phone with role PHONE, and remote machines pick it up from the key chain.

**Losing the phone.** Nothing on the phone is needed to recover. Josh pairs the
new phone the same way, and the MacBook signs a key set without the lost one.
Requests go to the Mac panel in the meantime.

## Contract

All additions are compatible. Field numbers already in use do not change.

- `bundle.proto`: `PhoneDecision` and `SignedPhoneDecision` (Josh's answer,
  signed over its exact bytes); `SignedDecision.phone_decision` (6);
  `DecisionAuthority.PHONE` (4).
- `relay.proto`: `ApproverKey.role` (5) with `ApproverRole` MAC, PHONE,
  MAC_DELIVERY; `EscalateToPhone(PhoneEscalation)` from the MacBook;
  `AnswerFromPhone(SignedPhoneDecision)` from the phone;
  `ApproverWork.phone_decision` (6) to the MacBook; wire fields 23 and 24.
- `PhoneEscalation.local_lease` (3) identifies a local lease without enrolling
  the Mac's local socket as a remote receiver. `PendingRequest` carries the
  source Mac key ID (2) and the local lease snapshot (3) to the phone.
- `UpdateLocalPhoneLease` (wire 25) acknowledges and mirrors actual local
  outcomes. `ApproverWork.local_lease_action` (7) carries the phone's existing
  End and Let it ask again actions to the Mac that owns the local lease.
- `PushRegistration.escalation_delay_seconds` is unused from now on: the
  MacBook runs the delay.

Checks, in order:

1. The phone signs only an escalated request it fetched from the relay over
   its pinned connection, and shows what it signs. Site, account and rule come
   from the rule owner's signed configuration, not a phone vault. For remote
   requests it checks the machine is in that configuration. For local requests
   it shows the source Mac's pinned label and checks the snapshot against the
   record; that local recipient is not a remotely enrolled receiver. The Mac
   still checks the exact digest against its retained request before delivery.
2. The relay forwards a phone answer only for a request the MacBook escalated,
   and only from a key with role PHONE in the current key set.
3. The MacBook accepts it only if the phone key is in its own key set, the
   request digest matches the request it holds, the lease is still pending,
   and the decision time is within the request's pending lifetime. An approval
   must still be unexpired, with `decided < not_after <= decided + 1800`. It
   rechecks current rules and the recipient before committing; a Blocked login
   or revoked machine cannot be approved from an earlier phone screen.
4. For a remote machine, the MacBook signs a `DecisionStatement` with authority
   PHONE using its delivery key and attaches the phone's signed decision.
   The remote machine verifies both signatures and requires equal request
   digest, lease ID, choice, decision/approval time, deadline and reply hash.
   Both reply strings must be identical and match that hash. Recipient and
   receiver key must match the retained request and current enrolment. The
   outer ciphertext hash and opened bundle checks remain those of RFC 0005.

**Denials.** A plain phone denial has an empty signature and reply. The relay
accepts it only over that paired phone's pinned connection, for an escalated
request; the Mac may refuse on that basis because it grants nothing. Remote
delivery uses the existing unsigned `APPROVER_CONNECTION` denial. A denial
with a reply is Face ID signed and delivered with authority PHONE and both
signatures, in `Lease.signed_denial`, without a bundle. Historical replies
remain verifiable after the pending deadline; no approval lifetime is applied
to denial history.

### Local requests have one authority

The local lease store remains authoritative, including when the mini is down.
The Mac persists the exact `RequestRecord` bytes, their digest, the local
lease ID and the escalation due time together before sending. It uses the
existing local recipient and request identity, not a second lease request.
Only pending Ask requests escalate; Automatic and Blocked keep their rules.

`EscalateToPhone` over the pinned MAC connection creates a relay display copy
when `local_lease` is present. Its fields must match the record. The relay
records which MAC owns it, rejects a collision with a remote lease or another
owner, and acknowledges identical retries without another push. It never
serves a bundle or any client operation for this local copy. Without
`local_lease`, the record must match an existing remote request exactly.
Only escalated requests are sent to PHONE connections; MAC connections keep
receiving the normal remote backlog.

The Mac consumes a phone answer against the retained bytes and commits the
lease and a reporting outbox entry together. Local approval uses the phone's
original decision time and deadline, never `now + 1800`. A concurrent Touch ID
answer, cancellation or expiry uses the same atomic pending-state check.
Neither path can reopen a finished lease.

After either device answers, and after release, expiry or revocation, the Mac
sends `UpdateLocalPhoneLease`. The relay accepts it only from the recorded
owner, for the same digest and scope. It updates the display copy, stops
notifications, acknowledges the phone answer and streams the actual state.
Retries are idempotent; older snapshots cannot move state backwards or reopen
a terminal lease. Updates contain no password. The durable outbox and
escalation survive a Mac or relay restart.

For local copies, `RevokeLease` and `ClearDenial` queue `LocalLeaseAction` for
the owning Mac rather than claiming to change its authority. Return and show
the actual last-known lease until the Mac reports the change. The Mac applies
these idempotently, then reports via `UpdateLocalPhoneLease`; the relay retains
the action until that acknowledgement. Only a revoke or clearing the relevant
recipient/login denial may travel this way, never approval. Remote leases
continue using the existing relay methods unchanged.

### Signing roles are enforced, not just labelled

- MAC signs HUMAN decisions and key-set changes. Only the named MAC rule
  owner signs configurations (logins, rules, machines, the Automatic key).
- PHONE signs `PhoneDecision`. It cannot enrol machines, change keys or rules,
  or sign a configuration. Plain denial and actions that take access away use its
  pinned connection as above.
- MAC_DELIVERY signs PHONE deliveries with a valid attached phone decision,
  or AUTOMATIC_RULE decisions the current configuration allows. It never signs
  HUMAN decisions, key sets or configurations. It has no
  separate TLS identity: it is a signing key used by the Mac connection.
  Adding or rotating it is a MAC-signed key-set update, not pairing another
  device; it needs no `PairApprover` request or comparison code.

The relay, Mac and receivers enforce these limits on every relevant signature,
including each step of a key-set chain. Merely finding a key in the pinned set
is insufficient. Only the previously pinned Mac rule-owner key may interpret
a legacy unspecified role as MAC; other old keys need explicit roles and the
old phone key must be replaced as stated above.

### Delivery with the screen locked

The existing delivery key uses `WhenUnlockedThisDeviceOnly`; that does not
meet this contract. Provision its replacement with
`AfterFirstUnlockThisDeviceOnly` and private-key usage, without a biometric
flag, and publish it through a Touch ID signed key-set change. The Mac's TLS
identity and non-secret saved connection state must also be available after
login while the screen is locked. The human signing key keeps its biometric
and unlocked requirements. The configuration must name the replacement key
before it can sign Automatic decisions.

The Mac's current vault uses the macOS file-based keychain, unlike the relay
keys' data-protection keychain. Do not infer its behaviour from the similarly
named accessibility attribute or weaken/migrate the whole vault for this
change. Prove reading a dummy login, signing and delivering after the app
restarts with the screen locked. The user must have logged in and the login
keychain must be available; an explicitly locked keychain, logged-out session
or sleeping Mac reports unavailable. Remove the blanket screen-lock rejection
only where an otherwise valid phone decision or the configuration authorises
delivery. Never unlock the screen or ask for a second Mac biometric.
See Apple's [keychain accessibility guidance](https://developer.apple.com/forums/thread/724013)
and [After First Unlock](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly).

## Build slices

| Slice | Owner | What | Done when |
| --- | --- | --- | --- |
| R4.1 | Sol | Phone key with Face ID on every use; replace the old key; pairing adds role PHONE to the key set | The phone pairs with code and Touch ID; a remote machine accepts the new key set |
| R4.2 | Sol | Mac escalation and local state reporting, the delay setting, immediate escalation when the screen is locked, cancelling the phone when the panel answers first | Local and remote requests reach the phone; a Mac answer closes either; restart preserves the pending request and its deadline |
| R4.3 | Terra | Relay push: send Apple pushes with a token key, one notification per request (a stable collapse ID), development or production gateway matching the build; store escalations and phone answers | One request, one notification; a relay restart loses no answer |
| R4.4 | Sol | Phone answer: fetch on open, request screen, Face ID, signed decision, outbox, Deny with reply | Approve over mobile data; cut the network after Face ID and restore it; one Face ID |
| R4.5 | Sol | Mac delivery under a phone decision, replacement background delivery key, exact phone deadline and local outcome reporting | With the Mac screen locked, a local agent and one on the mini each sign in after one phone approval; restarting the Mac app needs no second approval |
| R4.6 | Terra | Receivers verify authority PHONE: both signatures, same digest and deadline | A decision without a valid phone signature, or with a different deadline, is refused |
| R4.7 | Opus | Phone screens wired to the real backend (RFC 0007) | Every designed state renders from real requests |
| R4.8 | Sol | Remove the old iCloud approval channel and the custom microphone button and its permissions | The apps build without them and the entitlements no longer list them |

R4.1, R4.3 and R4.7 can start now. R4.5 needs R4.2 and R4.4.

**One Josh step:** an Apple push key (free, in his developer account) for
R4.3. Until it exists, requests appear when he opens the app but no
notification arrives.

## Device proofs for release 4

These need Josh with the MacBook and the iPhone.

- With the MacBook's screen locked and Josh away from it, an agent on the
  MacBook asks for an Ask login. The phone notifies within seconds, one Face ID
  approves, and the agent completes the sign-in.
- The same for an agent on the mini.
- At the MacBook, Touch ID answers before the delay and the phone is never
  notified.
- Race a Mac answer with a phone answer; one actual outcome appears on both.
  Release a local lease and end one from the phone; both screens follow the
  local store, including across a reconnect. A late answer changes nothing.
- With no phone import, and then a failed optional import, Home, pairing,
  pending requests and history all remain usable.
- Deny with a reply from the phone; the agent receives the reply.
- Phone on mobile data; then with another VPN active, to record what happens
  to the tailnet.
- Reboot the phone and restart the relay with a request waiting: one
  notification, one answer, no duplicate prompt.
- Whether a notification action can approve from the Lock Screen with Face ID.
  If not, Approve opens the app, as designed.

## Later: answering with the MacBook shut

Josh already wants availability independent of the MacBook. This remains the
next result to finish, not a new question about whether he wants it. The phone
then holds an encrypted copy of the
passwords and seals logins itself, through the same relay channel. Touch ID at
the MacBook stays, so the MacBook keeps its own copy too.

The earlier contracts below remain the starting point. Activating the phone
as a password source must explicitly extend its current approval-only role;
it does not hold or deliver passwords in this release.

**Import onto the phone.** Josh exports from Passwords on the iPhone to Agent
Keyring. Apple starts this only from the Passwords app, with his
authentication; no app can start or schedule it. The app merges additively and
seals each login to a Face ID protected Secure Enclave key. Refresh is the same
export; Apple offers no way to learn that a login changed.

**Login IDs.** IDs stay the MacBook's. The MacBook's signed configuration carries
the Apple item, account and exporter IDs for each login; the phone matches on
those, falls back to saved sites plus account only when exactly one login
matches on each side, and otherwise gives the item a new ID, starts it as Ask
and shows it for review. A rule never moves on a guess.

**Rule owner.** One device owns rules and login IDs, named in the approver key
set. Only it publishes the configuration; others fetch the newest one before
deciding and always deny a login it marks Blocked. The MacBook stays the owner unless Josh moves it.

**Automatic logins with the MacBook shut.** The rule owner seals Automatic
logins to the relay's own key and publishes them in the same
`ConfigurationPublication` as the configuration that names the relay's keys
and hashes the sealed logins. The relay then approves those leases itself,
and receivers check the configuration. Anyone who controls the mini can read
Automatic logins published this way.

**Phone approves and seals.** The phone opens the login with Face ID, seals it
to the receiving machine, and signs a HUMAN decision with its approver key, as
the MacBook does in RFC 0005.

**Settings for Josh at that point.** Whether to take the Mac mini off iCloud
Keychain, so Apple Passwords is not readable there without Agent Keyring, and
whether to turn Developer Mode off on the iPhone, so a replaced development
build cannot use the phone's keys.

**Device proofs at that point.** Import a selected test login and re-export a
changed one without losing the rest; match the MacBook's login IDs and record
how many match by Apple ID, by the fallback, and not at all; approve with the
MacBook shut.
