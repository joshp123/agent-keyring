---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
---

# Agent Keyring RFCs and build plan

Agent Keyring lets Josh's agents sign in with his saved logins while he stays
in control: each task gets one approval, the password goes into the sign-in
form instead of the chat, and he can answer with Touch ID at the MacBook or
Face ID on his iPhone.

| RFC | Covers | Release |
| --- | --- | --- |
| [0004](0004-credential-leases.md) | Task leases, the CLI, receivers, the bundled skill | 2 |
| [0005](0005-remote-requests.md) | Always-on relay on the Mac mini, enrolling agent machines, sealed delivery | 3 |
| [0006](0006-iphone-approver.md) | Phone approval without a phone vault; the awake Mac delivers | 4 |
| [0007](0007-approval-ui.md) | Approval screens on the Mac and iPhone | 2 to 4 |
| 0002, 0003 | Earlier drafts; superseded where 0004 to 0006 say so | |

Contracts: `proto/agentkeyring/v1/` (`agentkeyring.proto` for agents and
receivers, `bundle.proto` for sealed delivery, `relay.proto` for the relay and
approvers). Field numbers and names are stable; add, don't change.

## One seam, three parts

Agents always do the same four things: find a login, lease it for a task, use
it, release it. Behind that, three parts change independently:

- **Approver** decides. The MacBook holds the passwords and answers with Touch
  ID; from release 4 the iPhone answers with Face ID when Josh is away, and the
  MacBook delivers.
- **Transport** carries requests: the local socket now, the mini's relay from
  release 3.
- **Receiver** fills, submits and clears on the agent's machine, or hands the
  value to a program. Built once in release 2.

## Releases

| Release | Ships | Josh is needed for |
| --- | --- | --- |
| 1 (done) | Import that works, 0.2.4 notarised and installed, 542 logins | Done |
| 2 | One approval per task, Go CLI, Chromium receiver, bundled skill, Mac approval panel | One Touch ID session |
| 3 | Agents on other machines through the mini; MacBook approves | Pairing and enrolment codes, one Touch ID session |
| 4 | Approve on the iPhone when away from the MacBook; the MacBook keeps the passwords and delivers | Creating a free Apple push key; one device session |
| Next result | Answering with the MacBook shut: prove the phone copy independently of approval-only use | Phone import/device proof and two settings below |

## Slices

Owners are suggestions: Terra or Sol for non-UI code, Opus for UI, Astra
reviews. A slice is done when its "done when" passes on the installed build,
the way a person would use it.

| Release | Slices | Can start |
| --- | --- | --- |
| 2 | R2.0 additive merge and import logging port; R2.1 toolchain; R2.2 lease store; R2.3 socket cut-over; R2.4 Go CLI; R2.5 Chromium receiver; R2.6 skill and install; U1 to U3 screens | RFC 0004 reviewed with round 7 corrections; implementation can proceed |
| 3 | R3.1 relay core; R3.2 enrolment; R3.3 client relay transport; R3.4 Mac approver; R3.5 deployment; U4 | Contracts agreed with round 10 completions; all implementation lanes can start |
| 4 | R4.1 phone key and pairing; R4.2 Mac escalation and local state reporting; R4.3 relay push; R4.4 phone answer; R4.5 delivery while the Mac screen is locked; R4.6 receiver checks; R4.7 screens; R4.8 remove the iCloud channel and microphone button | Build against the round 15 contracts now; physical notification proof needs the push key |

## Review result and remaining engineering work

Astra agrees with the screen/backend boundary in 0007 and the release order.
Round 8 adds the missing sealed-bundle upload and approved request bytes,
binds denial replies, makes decision resends idempotent, and preserves the
configurable phone delay. Existing protobuf field numbers are unchanged.

Opus's revision and Astra's round 10 completions settle the three contract seams:

1. Pairing: unknown TLS peers may only enrol or pair; each device computes the
   full fingerprint from a defined transcript; the first approver is committed by a
   signed confirmation; codes bind the approver keys being trusted too; adding
   the phone binds the current signed machine roster in the new key set;
   offline receivers walk a signed approver key chain (0005).
2. Automatic approval: a separate Automatic key whose authority is an approver-
   signed grant from the rule owner listing logins and machines; decisions say
   which authority signed them, and receivers check the grant. The later
   MacBook-shut step publishes the grant and encrypted logins in one atomic
   snapshot (0005, 0006).
3. Phone copy, for the later MacBook-shut step: login IDs stay the MacBook's, matched by Apple source
   identity with a narrow fallback and review; one named rule owner publishes
   rules and grants; other approvers fetch that signed index through `GetIndex`
   (0006).

Release 3 and 4 lanes can build from these contracts. Existing field numbers
are unchanged; round 10 adds the missing pairing proofs, index and public-key
lookups, and exact bytes for Automatic sealing and hashing.

Device proofs remain necessary after implementation; compiler success is not
that proof.

Round 15 makes the approval-only path buildable: local requests keep one
authority on the Mac and report outcomes to the phone; signed phone consent
preserves its original deadline; delivery keys cannot sign changes to rules or
trusted keys. Phone import never gates approval. First relay setup brings Josh
the independent comparison code rather than sending him to service logs.
Direct APNs remains the notification path; RFC 0006 records why the existing
CloudKit entitlement is not evidence of a ready alternative.

Main's app version is 0.2.0; release 2 must ship above the installed 0.2.4.
Releases are built and notarised with `script/build_release.sh` on the current
Developer ID certificate. Nothing is published publicly without Josh's review.

## Proof standard

Each release has human proofs in its RFC. They use the installed app, CLI and
skill together, real agents, and real sign-ins with controlled test logins.
Device proofs (Touch ID, Face ID, credential exchange on the iPhone, Apple
pushes, Tailscale on the phone) are marked as such and only count when done on
the device. A synthetic test that passes is not a substitute.

## Settings for Josh, needed only for the later MacBook-shut step

1. Whether to take the Mac mini off iCloud Keychain, so Apple Passwords is not
   readable there without Agent Keyring.
2. Whether to turn Developer Mode off on the iPhone, so a replaced development
   build cannot use the phone's keys.

Release 4 needs neither. Touch ID at the keyboard stays: the passwords stay on
the MacBook.
