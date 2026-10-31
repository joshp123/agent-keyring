---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: revision 2 reviewed by Astra, 31 Oct; corrections below ready for Opus concurrence
supersedes: request and fill interface portions of RFC 0002
related: 0005 (remote requests), 0006 (iPhone authority), 0007 (approval UI); docs/rfc/README.md has the build plan
---

# RFC 0004: task leases and credential receivers

## What ships

A task gets permission to use one saved login, including retries and two-factor
steps, until it releases that permission or 30 minutes elapse. Touch ID remains
available on the Mac. The agent uses its existing browser or program.

Release 2 implements this locally. The same agent-facing messages separate the
credential authority from the receiving machine so later releases can move them
apart. They do not specify remote enrollment, encrypted credential delivery or
phone key ownership. Those security-bearing components need their own agreed
RFCs before implementation; exposing the local socket over TCP is not release 3.

Import repair is release 1. This RFC does not require replacing the entire
unreleased rebuild or waiting for phone development.

## What the agent does

An integration supplies a genuine task reference when it has one. Otherwise the
agent supplies a unique reference for the current job and keeps it through
retries; a reused human label is not sufficient across separate jobs:

```sh
task="invoice-check-1"  # example job reference, not the entire chat
lease=$(agent-keyring lease LOGIN --task "$task" --reason "Check the invoice Josh requested")
```

The default command waits and prints **only the active lease ID to stdout**.
Progress and errors go to stderr. A denial is a nonzero exit, with Josh's reply
if present. `--no-wait` returns a pending/active reference without waiting;
`agent-keyring status LEASE --wait` rejoins it without requesting approval.
Disconnecting a watcher does not cancel the request.

The model locates the sign-in controls using its normal browser tools. For the
Chromium receiver, it supplies the endpoint, tab, field selectors and submit
control. `--frame` (default: the main frame) and `--document` (the loader ID it
inspected; a changed document is then refused) are optional. The receiver checks
the frame's real origin against the saved login on every fill either way:

```sh
agent-keyring fill "$lease" --browser "$endpoint" --tab "$tab" \
  --username '#username' --password '#password' --submit 'button[type=submit]'
# Inspect the new page normally, then fill its next step under the same lease.
agent-keyring fill "$lease" --browser "$endpoint" --tab "$tab" \
  --code '#verification-code' --submit 'button[type=submit]'
# Continue the user's task; release when no further credential use is needed.
agent-keyring release "$lease"
```

The shell variables and selectors above are illustrative; the agent obtains the
actual targets from its browser tools. An integration can construct this typed
request directly. It does not pass a credential value through those tools.

For a program that needs the value, request that distinct purpose and command:

```sh
lease=$(agent-keyring lease LOGIN --task "$task" --for program \
  --reason "Sign in to the service Josh asked me to administer" \
  -- /absolute/path/to/client login --password-stdin)
agent-keyring exec "$lease" --field password
agent-keyring release "$lease"
```

The executable is an illustrative external client, not a new Keyring command.
The receiver resolves the executable on its own machine before requesting
approval. The approved command and arguments cannot be replaced at execution.
This is not a program attestation: the program may be agent-controlled.

The value goes to child stdin, with no shell expansion, credential-bearing argv
or environment. The receiver runs the child as the requesting OS user, never
with vault/service privileges. It returns exit status and safe outcome text,
not child stdout/stderr, because arbitrary children can print their input.
Do not silently turn failed browser filling into program delivery.

Some agent browsers have no receiver yet. One explicit value route stays for
agent runtimes that permit credential entry through their own code, preserving
the existing capability under a lease:

```sh
lease=$(agent-keyring lease LOGIN --task "$task" --for agent-process \
  --reason "Sign in using my runtime's permitted credential-entry tool")
# The runtime's code spawns `agent-keyring read LEASE --field password`,
# consumes its stdout privately and passes it directly to that permitted tool.
# Do not run `read` as a standalone model-visible shell tool call.
```

`read` refuses a terminal; a pipe alone does not make output private, because
ordinary shell tools capture stdout for the model. The skill identifies this
route as value delivery to the agent's code, with no echo or transcript output.
It is usable only where the harness permits that input path; it does not bypass
a browser tool's restrictions. The approval says plainly "Give the password
to the agent's own code". This is
today's retained-buffer route under a lease, with no protection claim: the
model's code holds the value. It replaces the named-pasteboard `acquire`,
`read` and `clear` commands and the hidden `agent-browser-plugin`. It is
replaced by the receiver in the skill when that integration is proved. Codex's
in-app browser is not claimed supported merely because its REPL can spawn a
process. Its permitted credential-entry integration still needs proof.

## Lease state and retries

The authority derives the caller from the authenticated connection and checks
its permitted recipient. A request selects one login, task, recipient and purpose.
Program requests also bind the command. Reasons are displayed as agent claims;
they do not authorize anything. Missing IDs, unspecified/unknown enum values,
and contradictory purpose/program fields are rejected.

- An exact retry with the same caller-scoped request ID returns the original
  record, including a terminal record. Changed content with that ID is an error.
- Concurrent new request IDs for the same caller, recipient, task, login and
  purpose join the pending/active record rather than creating another prompt.
  They cannot mutate its reason or approved program. A changed program in that
  scope is a conflict until the existing request is ended. Return the original
  scope and reason so callers can see what they joined.
- Different tasks do not share permission merely because the login is the same.
  Task identity is cooperative unless established by a trusted harness. A Codex
  thread or Claude session spanning several jobs is not automatically a task.
  Missing task context is an actionable error, never a global default.
- Ask prompts once for a new lease. Automatic approves each new lease without
  prompting. Blocked refuses; it cannot be escalated by the agent.
- Pending requests have a fixed ten-minute deadline, independent of the active
  lease deadline. The existing configurable phone escalation delay must fit
  within that deadline. A timed-out request is Unanswered, not a human denial.
- Approval sets an absolute deadline no later than approval time plus 30 minutes.
  Waiting, use, retries, reconnects and relay delivery never extend it. Automatic
  approval sets the same bounded lifetime.
- After a terminal state, an explicitly initiated new request gets a new request
  ID and is evaluated under current policy. Transport retries and status calls
  never create it. The CLI retains the request ID through retries of its current
  invocation; separate invocations rejoin existing pending/active scope.
- A human denial suppresses new requests for that recipient/login for 30 minutes,
  across task labels and delivery purposes. Josh can deliberately clear that
  suppression in the app. Blocked is independently enforced and does not expire.
  Do not automatically re-prompt when the suppression period ends.
- EndLease cancels Pending or releases Active. Terminal records stay terminal,
  including when an old approval arrives later. Only one decision activates a
  request; duplicate delivery of a decision has no further effect.
- Blocking a login, revoking the recipient, or changing Automatic to Ask revokes
  affected active leases. The authority checks current policy at every new
  delivery. An import cannot broaden the saved destination scope of an existing
  lease; removing its login invalidates it.
- Values are obtained for the operation and cleared promptly from Keyring's
  transient buffers. This does not revoke already delivered values, erase
  copies made by a child/page, terminate a program or log out the website.

Lease/request records persist through authority restart without restarting their
clocks or asking again. Restart does not silently reinterpret an unknown outcome
as permission to issue another request.

## Authority and receiver are different roles

`AgentKeyring` serves Find/Request/Get/Watch/End at the credential authority.
`CredentialReceiver` defines Fill/ExecuteProgram at the enrolled recipient.
Release 3 moves the request transport without moving a tab ID or executable
path to the vault host.

In release 2 the receiver is the `agent-keyring` client process itself: `fill`,
`exec` and `read` run the operation in-process and exit. There is no receiver
daemon. To act, the client calls the authority's `Deliver`, which returns only
the fields that operation needs. On the local socket `Deliver` returns plain
values. Any process running as the same user can call it with a lease ID,
which is the same-user limit stated below, not a new one. Release 3 returns a
bundle sealed to the enrolled receiver's key instead (RFC 0005); the receiver
code is the same apart from opening it.

The lease contains an authority-issued recipient ID and display labels obtained
from registration, not an arbitrary request string. On an authenticated local
connection, an empty request recipient selects the authority's persistent
co-located receiver record for that OS user. The returned lease always names it.
Remote requests name the enrolled recipient. A caller cannot turn another name
or PID into authority.

In release 2 the Unix socket authenticates OS peers and restricts access to the
installed user's context. Peer identity is obtained from the OS, not a supplied
PID. Multiple agents with the same user's privileges remain one effective
security principal. Separate task IDs prevent accidental mixing; they do not
isolate hostile same-user processes. Do not invent verified agent identities
from process names. A lease ID alone grants no access across principals.

The authority checks the authenticated caller, lease recipient, active state,
current policy, and operation kind before `Deliver` returns anything.
Fill requires browser purpose, ExecuteProgram requires program purpose, and Read
requires agent-process purpose. Fields must be known, nonempty, nonduplicated and
available; ExecuteProgram and Read select exactly one. An unavailable field
fails the whole delivery without asking again. Only
requested fields are returned. The browser and command checks are in the client;
they are not a separate trust boundary from same-user software. There is no
caller-chosen decryption key.
A remote receiver needs the separately specified authenticated delivery channel;
a mutable broker's claim that a lease is approved will not suffice.

Program execution happens under the requesting user's authority. Do not put a
general command execution API in a privileged vault daemon. If the process layout
cannot meet that condition, the program receiver remains unavailable.

## Filling is explicit plumbing

The model chooses which account and controls to use. The receiver:

1. Validates the intended browser endpoint, tab, frame and document, and reads
   the frame's actual origin under the saved destination policy. A loopback
   address by itself does not prove the endpoint is a browser. A caller's fake
   debugging server must not be accepted as origin evidence.
2. Resolves each plain CSS selector to exactly one appropriate editable element
   in that frame, and the submit selector to a suitable control. Password bindings
   require a password input; they cannot target an ordinary chat/search field.
   It validates all targets before obtaining values. Unknown fields, missing/ambiguous
   elements and unsupported targets fail without a new approval prompt.
3. Fills the supplied bindings, obtains a current TOTP code when requested
   (never the seed), submits that sign-in step, and clears inserted values that
   remain before reporting completion. It rechecks target identity if the
   document changes during preparation. It does not return DOM values.
4. Reports submitted, refused, uncertain or cleanup failed honestly. Submitted
   is not proof of authentication. A URL change alone is not proof that every
   inserted value disappeared. If cleanup fails, report that failure rather than
   claiming safe completion; the skill avoids reading sensitive fields and can
   close the affected tab using its ordinary browser tool.

Selectors and a submit control remove the need for form guessing, site plugins
or a universal login state machine. The initial receiver need not support every
shadow-DOM or split-code widget. It reports unsupported shapes without falling
back to arbitrary JavaScript or global keyboard input.

**Operations and retries.** The machine doing the operation keeps the record.
The client already has a persistent, owner-only state file, so retries are
remembered there and the authority only authorizes and delivers. (Earlier
drafts kept records at the authority; that added three remote calls per fill
and duplicate stores in Swift and Go, for receipts that are only the
receiver's own claims anyway.)

- An operation's digest covers the action, not the moment: lease, kind, validated
  browser instance, target tab and requested frame (empty means main), each field
  binding and selector, the submit control, and for programs the lease-bound
  command and selected field. Include an explicitly supplied document
  precondition, but leave out the current loader ID discovered by the receiver,
  so a submit that navigated before its reply was lost cannot turn a retry into
  a new action. The receiver sorts bindings by field and hashes an unambiguous
  length-prefixed encoding; it never includes values. Origin and document checks
  still run before any new fill.
- The operation key is `operation_id` if an integration passes one, otherwise
  the digest. `--again` and an explicit operation ID cannot be combined.
- The receiver takes a local file lock for the browser tab (or the lease, for
  programs), then looks the key up in its state file **before** validating any
  target. A known key is reported as recorded without touching the page: a
  retry after a submit that navigated would otherwise fail on selectors that
  no longer exist. A key that was started but has no outcome reports Uncertain.
- For a new key it validates the target, writes the record as Started and
  syncs the file, then calls `Deliver`, acts, and writes the outcome. A crash
  between those steps leaves Started, so the next attempt reports Uncertain and
  never submits twice.
- The next sign-in step, such as a code field, has different bindings, so it is
  a new operation without any flag.
- Repeating the same step deliberately, even on a new page, needs `--again` on
  `fill` or `exec`. That makes a fresh key after inspecting the result. A page
  change is not evidence that the preceding command failed. Store the exit
  code with an Exited outcome so a retried `exec` returns the original result.
- `read` is a new operation per explicit invocation; the agent asked for the
  value again. Another `read` under the active lease can retrieve it again,
  including a fresh code, without another approval.
- Records are deleted 24 hours after their lease's deadline. Serialize by tab,
  not by login. This is conservative retry handling, not exactly-once
  execution.

**What is kept, and for how long.** The Mac app's lease store and the relay's
store follow the same rule. Active leases are indexed by deadline; one timer
fires at the earliest deadline, and watchers are woken by changes, not by
polling. When a lease ends, its sealed bundle, phone answer and escalation are
deleted at once. The ended lease and its request ID are kept for 7 days, which
is enough to answer late retries with the original outcome, enforce a denial's
30-minute suppression and show recent history, and then deleted. Pending
enrolments and pairings are deleted after 10 minutes.

## Receiver evidence and release scope

- **Chromium debugging receiver:** earlier notes report dummy-page fill,
  submission and residual clearing on the mini. They also report a second
  debugger capturing the submitted value. This is a primitive feasibility
  result, not proof of this receiver, real sites, endpoint authentication,
  crash-safe retries or an actual Codex/Claude tool integration.
- **Safari and visible Chrome/Claude/Codex browsers through Accessibility:**
  proposed, not proved. Current source posts global keyboard events; it does
  not implement exact-element assignment, submission and cleanup. A window ID
  is not an element selector. This proto deliberately omits the old ambiguous
  MacWindowTarget. An AX receiver needs a concrete element/submit contract and
  per-browser feasibility before a new target variant is enabled.
- **Built-in or hosted browsers without a compatible receiver:** a known
  coverage gap. Do not claim support, switch the user's browser silently, or
  call a raw-value skill workaround protected filling.
- **Program receiver:** defined here, not yet proved. It exposes the selected
  value to that child, which may retain or transmit it. It is not a substitute
  for a browser integration.

The local lease/CLI lane may ship independently while a receiver is unfinished,
using explicitly described existing delivery routes. An unfinished receiver
returns unsupported/unavailable; no placeholder reports success. Stronger
browser protection is claimed only for a demonstrated integration.

## What this protects

Agent-facing lease messages and receiver results contain no passwords, OTP
codes or seeds. Only `Deliver`'s reply to the receiver carries values,
and the client never prints it except through `read` for the agent-process
purpose. Find deliberately exposes login/account metadata to authorized callers.
This reduces accidental disclosure through the normal tool path; it does not
prove the model never sees a value through some other tool. A program can write
its input elsewhere, and a browser-controlling agent can install capture hooks
or use another debugger. An isolated JavaScript context does not make shared DOM
values secret. Pausing all relevant agent observations needs a harness
integration and is not supplied by a synchronous CLI call.

The Mac-held vault also retains its existing host-administration limits during
this release. This RFC does not claim the later phone trust boundary is deployed.

## The bundled skill and the bitter lesson

One canonical skill ships with each executable distribution, inside the Mac app
and alongside the later Linux client. `agent-keyring skill` prints the instructions
for that installed version; `--help` remains the command reference.

`install` makes Codex/Claude instructions resolve to that bundled version where
the harness supports it, or refreshes an owned installed copy as part of update.
Do not overwrite user-authored skills. Current source copies skill text during
installation; an app update alone does not update those copies. The implementation
must close that gap and test the installed instructions, not merely edit the repo.

The skill is short and operational: discover/select the account; establish the
current task; request once; wait on the same reference; inspect the page and pass
exact targets; reuse the lease through retries and OTP; release when done.
Explain denied/expired/uncertain states, actual supported receivers, and the
separate program and agent-process purposes. SMS/email codes come from the agent's
existing authorized tools. It distinguishes a private value pipe from tool output
visible to the model. It never recommends displaying a secret, broadening access
rules, changing browsers silently, or changing delivery purpose to get around a
refusal. An approved browser lease cannot be used with `read` or `exec`.
The old plaintext-returning agent-browser plugin is not the new Fill interface.

Code enforces identity, policy, lifetimes, target validity and delivery. The model
chooses the account, page controls, next step, completion and communication.
No site risk scores, keyword-based judgements or bespoke per-site login recipes.
Progress is available to the agent, not a requirement to relay every state change
to Josh. Interrupt him only when his action is needed.

## Wire contract

`proto/agentkeyring/v1/agentkeyring.proto` defines both service roles and the local
wire messages. These are not gRPC frames. Each connection handles one method:
four-byte big-endian length, then one protobuf WireRequest; responses use the
same framing and WireResponse. Frames are limited to 1 MiB. Unary replies end the
stream; Watch first emits current state, then changes until terminal/error.
No method-name strings or multiplexing. Invalid/unknown enum values and missing
required oneof variants are rejected, not interpreted as defaults. Safe typed
errors are available on every method.

The authority socket handles Find/Request/Get/Watch/End/Begin/Finish only.
Fill/ExecuteProgram describe local client operations; their existing wire fields
remain assigned to that role and the authority rejects them. It never executes
a browser or program target named in a socket request.

Release 2 uses a user-restricted Unix socket. The Go CLI is a new implementation;
the current bundled CLI is Swift, so packaging must deliberately select the new
binary rather than accidentally leave the old one installed. Network transport,
enrollment and encrypted authority-to-receiver delivery are later components.
Preserve message semantics and field numbers; compatible additions are expected.
Do not promise that every internal protocol is already complete or frozen.

## Proof before calling release 2 complete

Use installed app/CLI/skill versions together. Exercise an actual supported
Codex and Claude login path with one approval per account/task, including a retry
and a later code step. Check the authenticated website result, release, expiry,
fresh Automatic/Ask behavior, and a denial reply.

Also exercise separate tasks, conflicting retry IDs, wrong recipient/purpose,
target navigation, a lost submit result after navigation, receiver/authority
restart, a lost child-exit result and a program
that deliberately echoes its fixture input. None may trigger an unrequested
approval or leak that fixture through Fill/ExecuteProgram output. Check `read`
separately with a private consumer: only its explicitly requested pipe receives
the fixture, never diagnostics or the model-facing transcript.

`script/check_login_artifacts.py` checks selected text artifacts for fixture
values and some encodings. It does not prove absence from all transcripts,
screenshots, recordings or process memory. Inspect the actual harness artifacts
and rendered behavior too. Use controlled credentials for repeatable checks and
the planned physical-device session for Touch ID.

## Code base and migration

Release 1 ships from the installed 0.2.3 source (`12e11b1`) plus the import
fixes on `fix/import-024`. Release 2 builds on `main`, which already has the
Unix socket server, peer identity, signed rules and fill helper, with the
release 1 commits brought across first.

| Today on `main` | Release 2 |
| --- | --- |
| JSON frames on `agent.sock` | Protobuf frames from this proto, same socket path. One cut-over; the old CLI is removed in the same build |
| `CredentialApprovalGrants`, keyed by harness process, in memory | Lease records on disk, keyed as in "Lease state and retries" |
| `HarnessSessionRequestQueue` | Deleted. Joining an existing pending request replaces queueing |
| Swift `agent-keyring` CLI | Go CLI, bundled in `Contents/Helpers`, built by the same release script |
| `acquire`/`read`/`clear` on named pasteboards | `read LEASE` for the agent-process purpose only |
| `agent-browser-plugin` (prints plaintext JSON) | Deleted |
| `fill username/password/code` with global key events | Not shipped as a receiver. Kept off unless a per-browser proof passes (open item below) |
| Copied `SKILL.md` | Bundled skill, `agent-keyring skill`, install refreshes owned copies |

An installed 0.2.x agent that runs an old command gets a short error naming the
new command. Existing access rules and the mirror carry over unchanged.

The partial-export wipe found by Astra (`scope: .full` plus a merger that keeps
only incoming items) is not fixed on `fix/import-024`. It is slice R2.0 below
unless the import lane fixes it first.

## Build slices

Each slice ends in something a person can run. Owners: Terra or Sol for
non-UI code, Opus for UI, Astra for review. Slices in the same column can run
in parallel.

| Slice | What | Done when |
| --- | --- | --- |
| R2.0 | Additive merge: a selected export updates and adds; items missing from it stay; a full export shows removals for review | Export one changed login and the other 520 are still there with their rules |
| R2.1 | Toolchain: `devenv` with Go, `protoc`, `protoc-gen-go`, `protoc-gen-swift`; generated code committed; one script regenerates | A clean checkout builds both sides from the proto |
| R2.2 | Authority lease store in the Mac app: records on disk, request joining, deadlines, denial suppression, revocation on rule change, 7-day retention with a deadline timer | Leases survive an app restart without a second prompt or a reset clock |
| R2.3 | Socket cut-over to protobuf framing with `Deliver` | Old JSON clients get a clear error; the Go CLI round-trips every method |
| R2.4 | Go CLI: `find`, `lease`, `status`, `release`, `exec`, `read`, `skill`, `install`, human output, stdout carries only the lease ID or the value | A shell agent completes a program login and an agent-process login with one Touch ID |
| R2.5 | Chromium receiver in the Go CLI: endpoint check, origin check, element checks, fill, submit, clear, digest | Dummy and real low-value logins on the mini's debug-port Chrome, including a two-step code login; retries return the recorded result or Uncertain without a second submit, including after navigation |
| R2.6 | Skill text and install | A fresh Codex and Claude session follow it unaided to a signed-in site |
| R2.7 | Mac approval panel and menu bar (RFC 0007) | Josh approves at the MacBook with one touch while typing elsewhere, and nothing is approved by typing |

R2.2 and R2.3 come before R2.4 and R2.5 can finish. R2.0, R2.1, R2.5 against a
fake authority, and R2.7 against mock backends can start at once.

## Open items that do not block release 2

- **Visible-browser fill on the Mac (Safari, real-profile Chrome, Claude's
  pane).** The existing global-keystroke filler is not exact-element filling.
  A proof per browser decides whether an exact-element Accessibility receiver
  is possible; Cua's notes say WebKit ignores AXValue writes. An agent-process
  route is available only where the harness permits it and it has been proved.
- **Codex's in-app browser.** No supported receiver path exists. Its
  `browserAuth` capability hands sign-in to Josh or 1Password. The dependency
  is OpenAI opening that to other password managers.
- **Same-user agents.** One principal, as stated above. Not fixed by any slice.

## Review disposition

Astra agrees with implementing the local lease/CLI and explicit receiver shapes
above. Opus concurs, with one simplification made on 31 Oct: frame and document
IDs are optional for agents, because the receiver checks the real origin on every
fill anyway. (An earlier simplification kept operation receipts in receiver
memory; revision 2 below replaces it.) The remaining disagreements with the original
draft were resolved here: whole-chat task defaults, stdout mixed with progress,
unspecified program delivery, implicit form discovery, window-as-element targets,
and treating a remote receiver as the authority's local browser.

Revision 2 (Opus, 31 Oct), for Astra's review: operation records move from
receiver memory to the authority's lease records, with receiver-computed
digests, because the receiver is a short-lived process; the agent-process
purpose keeps today's working route for browsers without a receiver, under a
lease and labelled honestly; `Deliver` names the
internal delivery path the first draft left implicit.

Astra's round 7 corrections: keep retry identity stable across navigation and
CLI restart; make deliberate repeats explicit; retain program exit status;
specify Begin/Finish checks and cross-process tab serialization; and distinguish
the explicit value route from proven browser support. These correct the existing
operating path without adding product scope. With them, Astra agrees to
implementation; Opus can concur before starting the build lanes.

Round 9 simplification (Opus, after a fresh Astra review for Josh): operation
records move from the authority to the receiver's own state file, so
`BeginOperation`, `FinishOperation` and `GetOperation` become one `Deliver`
call; retention is bounded (7 days for ended leases, 24 hours for receiver
records) and deadlines use a timer instead of scans.

Still unproved: production browser endpoint binding, exact AX filling, actual
harness coverage, and the final phone/Touch ID authority arrangement. These are
named component/release checks, not grounds to block the independent import fix
or to report an unsupported receiver as working.
