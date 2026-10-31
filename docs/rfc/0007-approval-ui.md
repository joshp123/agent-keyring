---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: agreed for implementation; U1 built; designs remain a placeholder for Josh's review
depends_on: 0004; 0005 and 0006 for remote and phone states
related: docs/design/, AgentKeyringPackage/Sources/AgentKeyringApprovalUI
---

# RFC 0007: approval screens on the Mac and the iPhone

## What ships

The screens Josh uses to answer agents: a small approval panel and a menu bar
window on the Mac, a rules window, and the iPhone app. The designs
(`docs/design/README.md`, `mac.md`, `iphone.md`, screenshots in
`docs/design/screens/`) are the starting point. Josh has not
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

Every protocol has the same shape: a stream of updates (the current value
first, then each change), plus one async call per thing Josh can do. Views
never poll and never build a lease.

| Protocol | Updates | Actions |
| --- | --- | --- |
| `MacApprovalBackend` | `updates(requestID:)`: one request until it is final | `approve`, `deny(reply:)`, `embeddedTouchIDContext` |
| `MacMenuBarBackend` | `updates()`: all requests plus the import count and date | `endAccess`, `allowAskingAgain` |
| `LoginRulesBackend` | `updates()`: logins with rules, plus a pending confirmation | `setRule`, `confirmRules` |
| `PhoneKeyringBackend` | `updates()`: requests, passwords, connection, settings | `approve`, `deny`, `endAccess`, `allowAskingAgain`, `openPasswordsForImport`, `setAskPhoneAfter`, `dictation` |

`embeddedTouchIDContext` returns the `LAContext` that `approve` will evaluate.
The panel shows it with `LAAuthenticationView`, starts the evaluation as it
opens, and a touch on the sensor approves with no click. Deny cancels the
evaluation. Returning nil gives a plain Approve button and the system prompt.

### From a lease to a screen

Backends build `AccessRequest` (`Shared/AccessRequest.swift`) from a `Lease`.
Views never see protobuf types.

| `Lease.state` | `AccessRequestState` | Shown |
| --- | --- | --- |
| PENDING | `waitingForYou(until: pending_until)` | Waiting, countdown, Deny and Approve |
| ACTIVE | `approved(by: approved_by, until: not_after)` | "Approved … until 01:53", End now |
| DENIED | `denied(by:, reply:, askAgainAfter: retry_not_before)` | "Denied", the reply, Let it ask again while held off |
| UNANSWERED | `unanswered` | "Nobody answered" |
| CANCELLED | `cancelled` | "Withdrawn" |
| EXPIRED | `expired(at:)` | "Ended … after 30 minutes" |
| RELEASED | `released(at:)` | "Done" |
| REVOKED | `ended(at:)` | "You ended it" |
| (refused by a Blocked rule) | `blockedByRule` | "Blocked", only if the authority records refusals |

`sendingAnswer` is the screen's own state between Josh's tap and the
authority's reply; a backend never produces it.

| `Lease.purpose` | `RequestedAccess` | Access line |
| --- | --- | --- |
| BROWSER_SIGN_IN | `signIn` | "Sign-in only, up to 30 min" |
| PROGRAM | `program(command)` | "Password to gh, up to 30 min", and the command on its own line |
| AGENT_PROCESS | `agentProcess` | "Password to Codex's own code, up to 30 min"; headline "Codex wants the password itself for" |

`AccessRequest`, the value every request screen shows, is built from these
sources only:

| Shown | Source | Shown as |
| --- | --- | --- |
| Site and account | The approver's own vault record for `login_id` | Fact |
| Machine | Approver's own approved enrolment record, or local peer | Enrolled identity, in the facts list |
| Tailnet address | Relay's connection lookup | Address reported by the relay, not independent identity proof; shown next to the machine |
| Purpose and limit ("Sign-in only, up to 30 min", "Password to gh, up to 30 min", "Password to Codex's own code, up to 30 min") | Lease purpose and program | Requested operation, not a guarantee of how a program uses the password |
| Agent name and folder | Process attribution locally; `agent_label` remotely | Claim: the name heads the claim block ("Codex says"), the folder sits under the quote |
| Reason | Lease `reason` | Claim, quoted, "From the agent. Agent Keyring can't check it." |
| Time left | `pending_until` | Fact |
| When asked, when it ended | Lease record times | Fact, in history and the menu bar |

The agent-process purpose (RFC 0004) has its own wording so Josh can see that
the value goes to the agent's code: headline "Codex wants the password itself
for", access "Password to Codex's own code". It is never rendered as sign-in.

The facts list on a request holds only Machine, Access and, for a program,
Command. The agent's name stays in the headline because it is how Josh knows
which of his agents is asking; the claim block says where it came from.

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
| U1 | Opus | Merge `AgentKeyringApprovalUI` from the design branch into main behind the four protocols, with mock backends kept for the design gallery | Done: main builds (package, Mac app, iPhone app); every state renders from the real views (`docs/design/screens/`) |
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

## What U2 and U3 need from the release 2 lease store

Checked against the store's code on branch `t3/persistent-credential-leases`
(`CredentialLeaseStore`, `MirrorCredentialGrants`): `leaseStore.leases`,
`waitingRequests`, `activeLeases`, `changes()` and `requester(for:)`;
`approveLeaseWithTouchID(id)`, `denyLease(id, reply:)`, `leaseStore.end(id)`,
`clearDenial(loginID:)`, and `automaticallyPromptForLeases = false` to retire
the transitional system prompt. U2 and U3 are adapters over it:

| Screen needs | From the store |
| --- | --- |
| `updates(requestID:)`, `updates()` | `changes()`, filtered and mapped with the tables above |
| Agent name, folder, machine, address | `requester(for:)` |
| `approve` | `approveLeaseWithTouchID(id)` |
| `deny(reply:)` | `denyLease(id, reply:)` |
| `endAccess` | `leaseStore.end(id)` (see gap 2) |
| `allowAskingAgain` | `clearDenial(loginID:)` |
| More waiting | `waitingRequests.count - 1` |

Gaps to close in the store, smallest first:

1. **When it was asked and when it ended.** `Lease` has no request time and no
   end time, and the store keeps neither. History rows and the menu bar show
   both ("23:51 instagram.com", "finished at 01:20"). Keep them on the record
   and add `requested_at_unix_seconds = 17` and `ended_at_unix_seconds = 18`
   to `Lease`.
2. **Josh ending access is not the agent releasing it.** `end(id)` turns an
   active lease into RELEASED, so the screen would say "Codex finished with
   it" when Josh ended it, and `endAllGrants` does the same. Add a
   Josh-side `revoke(id)` that records REVOKED; keep `end` for the agent's
   EndLease.
3. **Touch ID without a click.** `approveLeaseWithTouchID(id)` runs the
   system prompt through the authorizer, so approving takes a click and a
   touch. Add `approveLeaseWithTouchID(id, context: LAContext)` that evaluates
   the panel's context and invalidates it if its task is cancelled. Whether
   this works from a non-activating panel is the MacBook device proof above.
4. **A cancelled Touch ID is not a denial.** Today a user-cancel from the
   authorizer denies the lease. With the embedded context, Deny cancels the
   evaluation and then calls `denyLease(id, reply:)`; if the cancel has
   already denied it, Josh's reply is lost. A cancelled evaluation should
   leave the lease pending; only `denyLease` denies.
5. **Denial hold-off scope.** RFC 0004 holds off one recipient and login;
   `clearDenial(loginID:)` clears every recipient. Fine for release 2, which
   has one recipient; take a recipient too before release 3.

The rules window (U3) does not use the lease store: its adapter wraps
`CredentialAccessController` (`rows`, `setPolicy`, `needsConfirmation`,
`confirmationSummary`, `confirmRules`).
