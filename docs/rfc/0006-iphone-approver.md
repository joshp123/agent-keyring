---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: revised 31 Oct around "phone approves, Mac delivers"; Astra review pending
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

This is release 4. Its one limit: the MacBook must be awake, because it holds
the passwords. Answering with the MacBook shut needs the phone to hold the
passwords too; that is the later step at the end of this RFC.

## How a request reaches Josh

1. An agent asks for a login. The request reaches the Mac app, from the local
   socket or from the relay (RFC 0005).
2. If Josh is at the MacBook, the approval panel appears and Touch ID answers
   it, as in release 2.
3. If the panel has not been answered after his delay, the Mac asks the iPhone.
   The delay is a Mac setting, 30 seconds to 10 minutes, default 2 minutes. If
   the Mac's screen is locked, it asks the iPhone at once, because nobody is at
   the keyboard.
4. The relay sends an Apple push: "An agent is asking for a login." No site,
   account or password is in the push.
5. Josh taps it. The app opens and shows the request: site and account, the
   agent and machine, the purpose and the 30-minute limit, and the agent's
   reason marked as its claim.
6. **Approve** asks for Face ID, then the phone signs its answer with a key in
   its Secure Enclave and sends it to the relay. **Deny** sends at once; a
   reply typed or dictated with the keyboard's microphone goes back to the agent.
7. The relay passes the answer to the MacBook. The MacBook checks it was
   signed by the paired phone for this exact request, then delivers: to a
   local agent directly, or sealed to a remote machine as in RFC 0005.
8. Whichever device answers first wins. The other screen shows "Answered on
   your Mac" or "Answered on your iPhone".

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

## What each device holds

| Device | Holds | Keys |
| --- | --- | --- |
| MacBook | The passwords and rules, as today | Touch ID approver key (role MAC); delivery key with no biometric check (role MAC_DELIVERY), the same key RFC 0005 uses for Automatic logins |
| iPhone | No passwords | Approver signing key in the Secure Enclave, Face ID on every use (role PHONE); TLS key for the relay |
| Mac mini | Requests and answers in transit, sealed logins for remote machines | Relay keys (RFC 0005) |

The phone's existing signing key was created without a Face ID requirement.
It is replaced, not reused.

## Protections and their limits

- **Only Josh's face approves on the phone.** The phone's key needs Face ID
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
- `PushRegistration.escalation_delay_seconds` is unused from now on: the
  MacBook runs the delay.

Checks, in order:

1. The phone signs only a request it fetched from the relay over its pinned
   connection, and shows what it signs.
2. The relay forwards a phone answer only for a request the MacBook escalated,
   and only from a key with role PHONE in the current key set.
3. The MacBook accepts it only if the phone key is in its own key set, the
   request digest matches the request it holds, the lease is still pending,
   and `not_after` is at most 30 minutes after the phone's decision time.
4. For a remote machine, the MacBook signs a `DecisionStatement` with authority
   PHONE using its delivery key, with the same digest and `not_after`, and
   attaches the phone's signed decision. The remote machine verifies both
   before opening the sealed login.

## Build slices

| Slice | Owner | What | Done when |
| --- | --- | --- | --- |
| R4.1 | Sol | Phone key with Face ID on every use; replace the old key; pairing adds role PHONE to the key set | The phone pairs with code and Touch ID; a remote machine accepts the new key set |
| R4.2 | Sol | Mac escalation: the delay setting, immediate escalation when the screen is locked, `EscalateToPhone`, cancelling the phone when the panel answers first | Answer at the Mac within the delay: no push. Lock the screen: the phone is asked at once |
| R4.3 | Terra | Relay push: send Apple pushes with a token key, one notification per request (a stable collapse ID), development or production gateway matching the build; store escalations and phone answers | One request, one notification; a relay restart loses no answer |
| R4.4 | Sol | Phone answer: fetch on open, request screen, Face ID, signed decision, outbox, Deny with reply | Approve over mobile data; cut the network after Face ID and restore it; one Face ID |
| R4.5 | Sol | Mac delivery under a phone decision: local agents directly; remote machines sealed with the delivery key and the attached phone decision | An agent on the MacBook and one on the mini each sign in after a phone approval |
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
- Deny with a reply from the phone; the agent receives the reply.
- Phone on mobile data; then with another VPN active, to record what happens
  to the tailnet.
- Reboot the phone and restart the relay with a request waiting: one
  notification, one answer, no duplicate prompt.
- Whether a notification action can approve from the Lock Screen with Face ID.
  If not, Approve opens the app, as designed.

## Later: answering with the MacBook shut

This is the step after release 4, and only if Josh wants approvals while the
MacBook is asleep or shut. The phone then holds an encrypted copy of the
passwords and seals logins itself, through the same relay channel. Touch ID at
the MacBook stays, so the MacBook keeps its own copy too.

The contracts below are settled with Astra so this can be built without
changing release 4.

**Import onto the phone.** Josh exports from Passwords on the iPhone to Agent
Keyring. Apple starts this only from the Passwords app, with his
authentication; no app can start or schedule it. The app merges additively and
seals each login to a Face ID protected Secure Enclave key. Refresh is the same
export; Apple offers no way to learn that a login changed.

**Login IDs.** IDs stay the MacBook's. The MacBook's signed login index carries
the Apple item, account and exporter IDs for each login; the phone matches on
those, falls back to saved sites plus account only when exactly one login
matches on each side, and otherwise gives the item a new ID, starts it as Ask
and shows it for review. A rule never moves on a guess.

**Rule owner.** One device owns rules and login IDs, named in the approver key
set. Only it publishes the login index and the Automatic grant; others fetch
the newest signed index before deciding and always deny a login it marks
Blocked. The MacBook stays the owner unless Josh moves it.

**Automatic logins with the MacBook shut.** The rule owner seals Automatic
logins to the relay's own key and signs a grant listing them and the machines
allowed them, in one snapshot. The relay then approves those leases itself,
and receivers check the grant. Anyone who controls the mini can read
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
