# Mac configuration, delivery and phone routing

Written by AI on 2026.10.31 by model gpt-6.1-sol.

Follow-up: [the joint Swift Mac/phone proof](mac-and-phone-joint.md) reruns the
full relay driver and exercises actual phone approval and Mac delivery. It
supersedes the relay-flow gap recorded below; hardware checks remain.

## Result and limits

The actual Mac Release app builds on the physical mini. Its signed build
launched there, served the bundled Go CLI and kept the confirmed example.com
Ask rule across replacement/restart. The current skill passed two uncoached
real Codex checks: a delayed approval followed by a two-step sign-in, and a
delayed denial followed by stopping. Both kept `lease` running for 150 seconds.

Those two answers came from the isolated Swift authority fixture's terminal
controls. They prove the skill, CLI, socket/store and headless browser flow.
They do **not** prove an answer through the app panel, Touch ID, phone pairing,
locked-screen delivery or Apple push.

The actual panel appeared and showed the login, account, machine, task scope,
agent claim and countdown. Its Approve button on the sensorless mini returned
“Touch ID didn't confirm. Nothing was shared.” The request stayed Pending.
Local credential approval requires biometrics or Apple Watch; the normal
password fallback used for **rules confirmation** is a separate path. No
approval requirement was weakened for the proof.

That actual-app Codex run was then stopped when tax work received exclusive
use of the mini's screen. The app and its pending panel were quit, its Codex
and computer-use children stopped, and all remaining work used shell/headless
interfaces. No further native input or window activation occurred.

The installed proof app used source `e00d9de`, with main through `e2118d7`.
The final mini build also includes `d1889f3` and `c6b00ef`; those change the
package target declaration and queued-phone deadline scheduling. The universal
CLI was built from the merged tree at `895f242`; none of the later lane commits
change the CLI. The designer's later screen commits are outside this proof build.

## Implementation

The local authority now serves `Deliver`. The receiver keeps its operation
receipts. The store keeps ended leases and request aliases for seven days and
uses one timer for lease, suppression, relay and escalation deadlines.

Rules, local revocations, the signed Configuration and the relay outbox share
one protected snapshot/checkpoint. A confirmed save queues publication as part
of that commit; `isApplying` stays true until publication is acknowledged.
The owner signs the MAC_DELIVERY key into the approver set before publishing
its Automatic key in the Configuration. Pending signed answers are persisted
and retried without another authorization.

The Mac retains exact local request bytes and the original pending deadline.
A paired phone receives pending Ask work after the configured delay or at once
when the screen is locked. A Mac answer before an unsent escalation removes
it. A possibly sent escalation receives the committed local outcome. Phone
answers are checked against the retained request, current rules, phone role,
signature and exact deadline before the first pending-state commit wins.
Remote phone delivery uses the same AfterFirstUnlock delivery key as Automatic;
the human key remains biometric and WhenUnlocked. All new Keychain state is
non-synchronizable. The old Mac CloudKit approval channel and entitlement are
removed.

## Screen interface

`ApprovalRoutingSettings.phoneDelaySeconds` remains the source of truth:
30–540 seconds, default 120. `RelayApprover` receives it as a closure, so the
store records the setting when a request is created; restarts do not restart
the delay.

`RelayApproverUpdate.isApplying` represents queued configuration publication.
`needsPublication` means the local logins/rules need owner confirmation for
other machines. First pairing's existing authorization now signs and queues
the initial Configuration too. Imports or differing local rules set
`CredentialAccessController.needsRelayPublicationConfirmation`; the Rules
window uses its existing confirmation band and `confirmRules()`.
`canConfirmRules` includes either local-rule or relay-publication confirmation.
A publication-only failure keeps local rules valid and leaves that control
available. The designer owns the screen adapters and has bound these states.

The existing relay pairing, enrolment, request, active lease, revoke, denial
clearing and snapshot-stream interfaces remain. The fixture's explicit
`publish`/`rule` owner commands still call `publishCurrentRules`; they stand in
for owner actions in that unbundled proof tool, not a product send button.

## Real Codex checks

The installed app's bundled CLI was on PATH; real agent skills were unchanged.
Each fresh `codex exec` used its normal account/configuration and a private
working/state directory. Its input was the current bundled `skill` output and
the plain sign-in task, with the later coordination restriction to headless
Chrome at 127.0.0.1:9222 and no visible windows/computer use. No waiting hints,
continuations or recovery coaching were sent.

For **Approve**, the owner answered after 150 seconds. No `turn.completed`
existed then. Codex obtained one lease, filled and submitted the password,
inspected the second page, submitted TOTP under the same lease, read “Signed in”
and “Synthetic account access succeeded.”, then released. Site counters were
one accepted password POST, one accepted verification POST and one signed-in
visit; unrelated fields stayed empty and the code form held no password.

For **Deny**, a fresh headless profile started at the sign-in page. After 150
seconds the turn was still open. The owner sent “Stop here. This is a denial
test; do not try again.” Codex received the CLI's nonzero result, quoted the
reply and stopped without retrying. Site counters did not change. Neither
replacement run used computer use. Browser inspection required a small stdlib
WebSocket client in the approval run because Node and Python's websocket
package were unavailable; the agent recovered without intervention.

The private raw events, exact prompt, terminal authority log, build log and
site counters are in `.private/proofs/r4-mac/`. The native own-panel screenshot
is there too: the surrounding desktop had unrelated personal work, so no
full desktop screenshot is published.

The terminal fixture launches without opening a window:

```sh
# ROOT is a fresh short path inside the signed app's container.
Authority.app/Contents/MacOS/Authority "$ROOT" --with-code
# Owner stdin: ask; then approve LEASE or deny LEASE REPLY.
# The CLI uses AGENT_KEYRING_SOCKET="$ROOT/agent.sock".
```

The fixture accepts only example.com data, is never bundled, substitutes the
owner's biometric step, and scopes its checkpoint service to ROOT's final
component. `--erase-test-checkpoint` deletes only that fixture checkpoint and
works even if its saved history cannot open.

## Other verification

The separate Go process exercised the production Swift socket/store fixture
with the actual bundled CLI: Automatic/join/conflict, requested fields and
purposes, restart/deadline retention, release, revocation, Ask restart/watch,
denial suppression/clearing, cancellation, every authority method, old JSON
migration errors and malformed frames. Modified and older valid snapshots
kept login discovery available but refused task access and named Reset task
history. Restoring the committed snapshot kept its original terminal leases.
The complete driver exited zero.

Its first run still expected damaged history to terminate the authority,
which the preceding recovery fix deliberately changed. The driver now checks
the actual recovery contract over the socket. A subsequent launch used an
overlong Unix socket path; the final isolated root was shortened and the full
driver passed. These were proof-driver/setup corrections, not accepted passes.

Both developer proof programs build and pass `go vet`. The complete Swift
package builds after removing the empty obsolete approval-core test target.
The actual Xcode Release app was built on the mini with the bundled universal
CLI, then built again after the exact queued-phone deadline correction.
No unit suite was added or run. The relay proof driver is adapted and builds;
its full relay flow has not been rerun in this round.

## Still needs the devices

On Touch ID hardware: first pairing/configuration publication, one-touch
shared-context rule changes, and real panel approval while another app is
active. With the paired phone: delayed/immediate-while-locked escalation,
Mac/phone answer races, exact phone deadline, locked background delivery,
lost acknowledgement plus restart without a second touch, and local outcome,
End and denial-clearing propagation. Apple notification delivery also needs
the separate push setup. These are explicit gaps in acceptance, not claims
inferred from a successful build or software-key fixture.

## Cleanup

The app was quit, its extension unregistered and the app moved to Trash.
`pluginkit` on the mini returned no credential-provider matches. The three
own Codex chats were archived; own Codex/CUA children, authority, server and
headless Chrome processes were stopped. Dummy mirror/rules/history, four
fixture roots, browser/client/task directories, signed wrappers, transferred
archives and the mini checkout/DerivedData were trashed.

Four fixture-specific non-synchronizable checkpoints were cleared. The dummy
app's checkpoint, rule signer/hash and vault key were cleared by the signed
upgrade tool after verifying the one example login. Its SSH launch could not
read the classic Keychain; running the tool in the GUI launchd domain with
Keychain interaction explicitly disabled succeeded, without opening a window
or authentication dialog. That one-shot job was then removed. No iCloud
Keychain items or other agents' processes/data were touched.

No new Agent Keyring/authority crash reports were present. Every local signed
staging bundle was trashed after transfer; the MacBook still lists only the
installed 0.2.5 credential-provider extension. No candidate/helper was launched
or installed there. No push or release occurred.
