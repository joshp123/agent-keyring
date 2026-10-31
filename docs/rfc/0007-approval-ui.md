---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: agreed for implementation; designs remain a placeholder for Josh's review
depends_on: 0004; 0005 and 0006 for remote and phone states
related: docs/design/ on branch t3/agentkeyring-app-design
---

# RFC 0007: approval screens on the Mac and the iPhone

## What ships

The screens Josh uses to answer agents: a small approval panel and a menu bar
window on the Mac, a rules window, and the iPhone app. The designs on branch
`t3/agentkeyring-app-design` (`docs/design/README.md`, `mac.md`, `iphone.md`,
screenshots in `docs/design/screens/`) are the starting point. Josh has not
reviewed them yet, so this RFC fixes the boundary between screens and logic
and leaves the look free to change. This agreement covers the view/backend
boundary, not a claim that the installed screens or biometric flow are proved.

## The boundary

Views read view models. Each view model talks to one backend protocol. Logic
lives behind the protocols, so a redesign changes views and copy, never leases
or approvals, and backend changes are localized. A changed product state may
still require a view-model and view change.

| View model | Backend protocol | Real backend, by release |
| --- | --- | --- |
| `MacApprovalModel` | `MacApprovalBackend` | Release 2: the Mac app's lease store. Release 3: also requests arriving from the relay |
| `MacMenuBarModel` | `MacMenuBarBackend` | Lease store (waiting, in use, recent) |
| `MacRulesModel` | `LoginRulesBackend` | Existing `CredentialAccessController`, keeping its "confirm your access rules" step |
| `PhoneKeyringModel` | `PhoneKeyringBackend` | Release 4: phone vault and relay connection |

`AccessRequest`, the value every request screen shows, is built from these
sources only:

| Shown | Source | Shown as |
| --- | --- | --- |
| Site and account | The approver's own vault record for `login_id` | Fact |
| Machine | Approver's own approved enrolment record, or local peer | Enrolled identity |
| Tailnet address | Relay's connection lookup | Address reported by the relay, not independent identity proof |
| Purpose and limit ("Fill sign-in, up to 30 min", "Password to a program", "Password to the agent's own code") | Lease purpose and program | Requested operation, not a guarantee of how a program uses the password |
| Agent name and folder | Process attribution locally; `agent_label` remotely | Claim |
| Reason | Lease `reason` | Claim, quoted, "Written by the agent. Agent Keyring can't check it." |
| Time left | `pending_until` | Fact |

The agent-process purpose (RFC 0004) gets its own plain wording so Josh can
see that the value goes to the agent's code.
The design branch's `RequestedAccess` currently has only signIn and program;
add agentProcess before wiring real requests. Never render it as signIn.

## Rules carried over from the designs and Josh's steering

- Site is the headline; Deny and Approve are equal size, red and green; reply
  is a kind of denial, with dictation.
- No risk badges, warning flags or verified-agent marks.
- The Mac panel never takes keyboard focus by itself, so typing elsewhere cannot
  answer it. Unproved: whether Touch ID can run from a non-activating panel
  without bringing the app forward (device proof below). If it cannot, the
  panel asks for one click before Touch ID and says why.
- After an answer, the screen shows the real state from the backend, never an
  assumed one: Sending until the authority acknowledges, then Approved, Denied,
  Unanswered or a transport failure. An accepted resend is already sent; a
  request answered elsewhere or expired must not invite another approval.
- Keep the configurable phone escalation delay and show its real pending state
  to the agent. A quick answer at the Mac cancels the phone notification.
- 24-hour times. Interrupt Josh only when his answer is needed.

## Build slices

| Slice | Owner | What | Done when |
| --- | --- | --- | --- |
| U1 | Opus | Merge `AgentKeyringApprovalUI` from the design branch into main behind the four protocols, with mock backends kept for the design gallery | Main builds; the gallery still renders every designed state |
| U2 | Opus | `MacApprovalBackend` over the release 2 lease store and Touch ID; panel supplies context while macOS performs biometric authorization | One touch approves a local request; Deny and reply returns the reply to the agent |
| U3 | Opus | `MacMenuBarBackend` and `LoginRulesBackend` | Menu bar shows waiting and in-use leases with End; rules change in place and keep the confirm step |
| U4 | Opus | Remote request and enrolment states on the Mac (release 3) | Josh can tell a remote request from a local one, and compares the enrolment code on screen |
| U5 | Opus | `PhoneKeyringBackend` over the phone vault and relay (release 4), Lock Screen notification | Every designed phone state renders from real requests |

## Human proofs

- **Device: MacBook, Josh present.** Approve with one touch while typing in
  another app; nothing typed reaches the panel; a failed touch shares nothing.
- **Device: iPhone.** One Face ID approves; Deny and reply with dictation
  reaches the agent; an unreachable relay shows the retrying banner.
- **Rendered check.** Screenshots of every state from the real views, light and
  dark, after U2 and U5. Josh reviews those, not mocks.
