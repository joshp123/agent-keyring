---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
---

# Agent Keyring RFCs and build plan

Agent Keyring lets Josh's agents sign in with his saved logins while he stays
in control: each task gets one approval, the password goes into the sign-in
form instead of the chat, and he can answer from the MacBook or, later, his
iPhone.

| RFC | Covers | Release |
| --- | --- | --- |
| [0004](0004-credential-leases.md) | Task leases, the CLI, receivers, the bundled skill | 2 |
| [0005](0005-remote-requests.md) | Always-on relay on the Mac mini, enrolling agent machines, sealed delivery | 3 |
| [0006](0006-iphone-approver.md) | iPhone import, Secure Enclave keys, approval, recovery | 4 |
| [0007](0007-approval-ui.md) | Approval screens on the Mac and iPhone | 2 to 4 |
| 0002, 0003 | Earlier drafts; superseded where 0004 to 0006 say so | |

Contracts: `proto/agentkeyring/v1/` (`agentkeyring.proto` for agents and
receivers, `bundle.proto` for sealed delivery, `relay.proto` for the relay and
approvers). Field numbers and names are stable; add, don't change.

## One seam, three parts

Agents always do the same four things: find a login, lease it for a task, use
it, release it. Behind that, three parts change independently:

- **Approver** holds the passwords and decides: MacBook now, iPhone added in
  release 4.
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
| 4 | iPhone imports and approves; MacBook can be shut | The device session and cutover decisions (RFC 0006) |

## Slices

Owners are suggestions: Terra or Sol for non-UI code, Opus for UI, Astra
reviews. A slice is done when its "done when" passes on the installed build,
the way a person would use it.

| Release | Slices | Can start |
| --- | --- | --- |
| 2 | R2.0 additive merge and import logging port; R2.1 toolchain; R2.2 lease store; R2.3 socket cut-over; R2.4 Go CLI; R2.5 Chromium receiver; R2.6 skill and install; U1 to U3 screens | RFC 0004 reviewed with round 7 corrections; implementation can proceed |
| 3 | R3.1 relay core; R3.2 enrolment; R3.3 client relay transport; R3.4 Mac approver; R3.5 deployment; U4 | Store, framing and bundle implementation can start; finish the pairing and Automatic contracts in 0005 before their dependent code |
| 4 | R4.1 phone import; R4.2 phone vault; R4.3 phone approver; R4.4 push; R4.5 approver key set; R4.6 Automatic publishing; U5; R4.8 cutover | Import, vault and screens can build with fixtures now; key/rule handover and Automatic need the contracts below; physical proof and cutover wait for Josh |

## Review result and remaining engineering work

Astra agrees with the screen/backend boundary in 0007 and the release order.
Round 8 adds the missing sealed-bundle upload and approved request bytes,
binds denial replies, makes decision resends idempotent, and preserves the
configurable phone delay. Existing protobuf field numbers are unchanged.

Three contract seams still need Opus/Astra agreement before their dependent
implementation, rather than each build agent inventing a different answer:

1. Pairing: bootstrap TLS permissions, independently checked codes, human
   confirmation and current approver/enrolment transfer (0005).
2. Unattended Automatic access: a signing/decryption path that works without
   biometrics and cannot be mistaken for Ask authority, with exact signed
   publication bytes (0005/0006).
3. Phone handover: shared login IDs, rule/index ownership and stale-device
   behavior under Josh's eventual desktop-authority choice (0006).

These do not block independent import, storage, transport or UI work. They are
engineering work for the collaborators, not extra questions for Josh. Device
proofs remain necessary after implementation; compiler success is not that proof.

Main's app version is 0.2.0; release 2 must ship above the installed 0.2.4.
Releases are built and notarised with `script/build_release.sh` on the current
Developer ID certificate. Nothing is published publicly without Josh's review.

## Proof standard

Each release has human proofs in its RFC. They use the installed app, CLI and
skill together, real agents, and real sign-ins with controlled test logins.
Device proofs (Touch ID, Face ID, credential exchange on the iPhone, Apple
pushes, Tailscale on the phone) are marked as such and only count when done on
the device. A synthetic test that passes is not a substitute.

## Open decisions for Josh

1. How Touch ID on the MacBook works once the iPhone holds the strong copy
   (RFC 0006, options A, B, C). Needed before the release 4 cutover only.
2. Whether to take the Mac mini off iCloud Keychain once the iPhone path works.
3. Whether to turn Developer Mode off on the iPhone after setup.
4. Review of the designs (RFC 0007). Building continues against them meanwhile.
