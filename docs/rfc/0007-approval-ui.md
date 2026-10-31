---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: agreed for implementation; U1 to U4 built, U2 and U4 awaiting device checks; designs remain a placeholder for Josh's review
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
| `PhoneKeyringModel` | `PhoneKeyringBackend` | Release 4: relay, signed login metadata and phone signing key; no vault dependency |

Every protocol has the same shape: a stream of updates (the current value
first, then each change), plus one async call per thing Josh can do. Views
never poll and never build a lease.

| Protocol | Updates | Actions |
| --- | --- | --- |
| `MacApprovalBackend` | `updates(requestID:)`: one request until it is final | `approve`, `deny(reply:)`, `embeddedTouchIDContext` |
| `MacMenuBarBackend` | `updates()`: all requests plus the import count and date | `endAccess`, `allowAskingAgain` |
| `LoginRulesBackend` | `updates()`: logins with rules, plus a pending confirmation | `setRule`, `confirmRules` |
| `PhoneKeyringBackend` | `updates()`: requests, connection, pairing; passwords only in the later MacBook-shut step | `approve`, `deny(reply:)`, `endAccess`, `allowAskingAgain`, `pair`; `openPasswordsForImport` only in the later step |

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
| Site and account | Mac: its vault record; approval-only phone: the rule owner's signed login index for `login_id` | Fact |
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
  is a kind of denial. The reply box is an ordinary text field: the iOS
  keyboard's own dictation covers speaking, so there is no custom microphone
  button and no microphone or speech permission.
- No risk badges, warning flags or verified-agent marks.
- The Mac panel never takes keyboard focus by itself, so typing elsewhere cannot
  answer it. Unproved: whether Touch ID can run from a non-activating panel
  without bringing the app forward (device proof below). If it cannot, the
  panel asks for one click before Touch ID and says why.
- After an answer, the screen shows the real state from the backend, never an
  assumed one: Sending until the authority acknowledges, then Approved, Denied,
  Unanswered or a transport failure. An accepted resend is already sent; a
  request answered elsewhere or expired must not invite another approval.
- The phone delay ("Ask iPhone after", 30 seconds to 9 minutes, default 2
  minutes) is a Mac setting, because the Mac decides when to ask the phone
  (RFC 0006). The phone's Settings screen shows it but does not change it.
  A locked Mac asks the phone at once. A quick answer at the Mac means no
  phone notification. The agent sees the real pending state.
- The phone screens work with no passwords on the phone. The import screen
  belongs to the later MacBook-shut step and must not block approving.
  Import status is separate from the request screen: a failed refresh cannot
  hide Home, pairing, pending requests, history or existing usable logins.
  Settings reports the real notification permission and registration result,
  never a successful placeholder. No Lock Screen promise before setup works.
- A phone answer accepted by the relay says "Waiting for your Mac" until the
  owning authority reports the actual outcome. A local End or Let it ask again
  action remains sending until the Mac acknowledges it (RFC 0006).
- 24-hour times. Interrupt Josh only when his answer is needed.

## Build slices

| Slice | Owner | What | Done when |
| --- | --- | --- | --- |
| U1 | Opus | Merge `AgentKeyringApprovalUI` from the design branch into main behind the four protocols, with mock backends kept for the design gallery | Done: main builds (package, Mac app, iPhone app); every state renders from the real views (`docs/design/screens/`) |
| U2 | Opus | `MacApprovalBackend` over the release 2 lease store and Touch ID; panel supplies context while macOS performs biometric authorization | Built (`LeaseApprovalBackend`, `LeaseApprovalPresenter`); proof is the MacBook check below |
| U3 | Opus | `MacMenuBarBackend` and `LoginRulesBackend` | Built (`LeaseMenuBarBackend`, `AccessRulesBackend`, `RulesWindow`); proof is the same check, plus the Mac UI tests |
| U4 | Opus | Remote request and enrolment states on the Mac (release 3) | Built over `RelayApprover`; proof is the release 3 MacBook check below |
| U5 | Opus | `PhoneKeyringBackend` over the relay (release 4): pairing, waiting requests, answer, outcome, in use; opens on Home, not on the import screen; reply box without the custom microphone | Every designed state renders from real requests, with no passwords on the phone |

## Human proofs

- **Device: MacBook, Josh present.** Approve with one touch while typing in
  another app; nothing typed reaches the panel; a failed touch shares nothing.
- **Device: iPhone.** One Face ID approves; Deny with a reply spoken through
  the keyboard's dictation reaches the agent; an unreachable relay shows the
  retrying banner.
- **Rendered check.** Screenshots of every state from the real views, light and
  dark, after U2 and U5. Josh reviews those, not mocks.

## How U2 and U3 are built

- **`AgentKeyringScreenBackends`** joins the lease store and access rules to
  the screens. `LeaseScreenMapping` is the only code that reads `Lease`;
  `LeaseApprovalBackend`, `LeaseMenuBarBackend` and `AccessRulesBackend` are
  thin calls into `MirrorAppModel`, `CredentialLeaseStore` and
  `CredentialAccessController`, observed with `Observations`.
- **Approval (U2).** `LeaseApprovalPresenter` in the app turns off
  `automaticallyPromptForLeases` before the socket opens, shows the panel for
  the oldest waiting lease, shows each outcome for 2.5 seconds, then moves to
  the next. With a usable Touch ID sensor the panel evaluates its own context
  through `approveLeaseWithTouchID(id, context:)`; without one (a closed
  laptop), Approve uses the system prompt, which can use an Apple Watch.
  Switching requests cancels any pending touch, because the store allows one
  approval in progress.
- **Menu bar (U3).** A `.window` menu bar extra over `LeaseMenuBarBackend`,
  followed from launch so the icon's waiting count is right. End revokes.
- **Rules (U3).** `RulesWindow` shows `MacRulesView` over
  `AccessRulesBackend`, with the existing AI assistant as a sheet. "Last
  used" is the login's last approved lease. The old rules views are removed.
- **Rendered from lease records.** The gallery's `leaseApproval` and
  `leaseMenuBar` screens map store-shaped lease records through
  `LeaseScreenMapping` (`docs/design/screens/mac/lease*.png`). The installed
  app with a live store is the morning check.

## How U4 is built

- **Remote at a glance.** A request knows whether it came from this Mac
  (`RequestingAgent.isLocal`). A remote one names the machine in the question
  ("Codex on Mac mini wants to sign in to"); lists say "This Mac" or the
  machine's name. A reply to a remote agent is signed, so "Deny and send"
  shows Touch ID; a plain Deny needs none. An answer still in the outbox says
  so under the outcome.
- **Comparing a code.** `FingerprintGrid` lays the eight groups out as two
  rows of four on every screen (Mac panel, Machines window, iPhone), so Josh
  compares the same positions on both. All eight must match; there is no
  shorter or picture form. "They match" approves with Touch ID.
- **Panels.** `ApprovalPresenter` shows one floating panel at a time:
  devices joining first, since someone is waiting at the other device, then
  requests from this Mac and through the relay, oldest first.
- **Backends.** `RelayScreenMapping` is the only code that reads relay
  records. `RelayApprovalBackend` (approve, deny, the panel's Touch ID
  context), `RelayEnrolmentBackend` (`approveEnrolment`,
  `confirmApproverPairing`, `denyEnrolment`) and `RelayMachinesBackend`
  (`beginPairing`, `confirmPairing`, `publishCurrentRules`, `revokeMachine`)
  wrap `RelayApprover`. The menu bar backend adds remote requests and leases;
  End calls `revokeLease`, "Let it ask again" calls `clearDenial` with the
  lease's recipient.
- **Machines window.** Relay setup, connection and outbox, rule changes not
  yet sent, devices waiting to join, machines that can ask (Remove), and
  devices that can approve. Opened from the menu bar's More menu.
  First setup brings Josh the independently obtained relay code over the
  existing trusted SSH path (RFC 0005); the screen refers to that setup code,
  never asks him to open service logs. Code comparison and Touch ID remain.
- **iPhone pairing.** Home says "Not paired yet" with Pair; Settings has
  "Pair with your Mac" and "Rules · Checked 11 minutes ago". The pairing
  screen takes the relay address (prefilled `mac-mini:17443`), shows the code
  in the same layout, and finishes by itself after the Mac approves.

"Doesn't match" refuses a joining machine (`denyEnrolment`), dismisses a
joining iPhone locally (`dismissApproverPairing`) and abandons an
unconfirmed first relay setup (`abandonPairing`). Each reports, in the
relay's words, when the answer was already signed. The relay address may be
any host name; the connection checks that it resolves to a tailnet address.

### Release 3 check on the MacBook

1. Run `agent-keyring enrol --name "build server"` on another machine. The
   Mac panel shows it with its code; compare all eight groups with the code
   the command printed, and touch "They match".
2. Ask an agent there to sign in somewhere. The panel reads "Codex on build
   server wants to sign in to"; one touch approves.
3. Open the menu bar: the lease is under "In use now" with the machine's
   name; End it.

## Morning check: one look, one touch

On the MacBook, with release 2 installed:

1. Ask any agent to lease the `example.com` login for a test task.
2. Click into another app and keep typing.
3. Look: the panel is at the top right with "Touch ID to approve", and
   what you typed went to the other app.
4. Touch the sensor: the panel says "Approved", the agent gets its lease,
   and the panel closes by itself.

Then, optionally: ask again and use **Deny and reply…**; the agent should
receive your reply. Open the menu bar to see the lease under "In use now"
and End it. If the panel shows an Approve button instead of "Touch ID to
approve", the Mac has no usable sensor at that moment; Approve then uses the
system prompt.

## What the store still lacks

Everything RFC 0007 asked for in round 2 is in the store. Three small gaps
remain:

1. **"Let it ask again" doesn't clear the lease's hold-off time.**
   `clearDenial(loginID:)` removes the suppression but leaves the denied
   lease's `retry_not_before_unix_seconds`, so the menu bar keeps offering
   "Let it ask again" until the 30 minutes pass. Zero it on that login's
   denied leases when the suppression is cleared.
2. **Blocked refusals aren't recorded.** A request for a Blocked login is
   refused without a lease record, so Recent never shows "Blocked". Fine
   to leave unless Josh wants to see refused attempts.
3. **Local requests have no address.** Local leases show "MacBook Pro · this
   Mac". Right for release 2; release 3 supplies the relay's address.
