# Actual-app upgrade and Codex sign-in

Written by AI on 2026.10.31 by model gpt-6.1-sol.

Ran on the physical Mac mini with synthetic example.com data only. The old
app was the MacBook's installed, signed and notarised 0.2.5, copied unchanged.
The replacement was the actual Release app built on the mini from `2f96a94`,
with the bundled universal Go CLI, signed on the MacBook with the existing
Developer ID identity and provisioning profiles. Its designated requirement
matched 0.2.5. No candidate or helper was launched on the MacBook. The final window check used
a rebuild including `0bbd02d`.

## Upgrade

The unbundled `agent-keyring-upgrade-state` tool prepared one encrypted dummy
login, its fixed test TOTP seed, and the 0.2.x mirror's required `delta` field.
No Apple Passwords import was attempted. The real 0.2.5 app and its bundled
Swift CLI read that mirror: one login, with username, password and code.

Two upgrades used the real `/Applications/AgentKeyring.app` path:

- One unsigned version-1 Automatic rule survived. The new Rules window showed
  one Automatic login and the upgrade explanation. One owner confirmation
  activated the rules; the bundled Go CLI obtained and released a lease.
- Empty unsigned version-1 records, matching the structure of Josh's installed
  state, became one Ask login. The new Rules window said: “Your logins and
  rules have been kept. Confirm them once to finish updating Agent Keyring.”
  It showed no unreadable-rules alarm and no iPhone warning. Before
  confirmation the CLI refused a lease. One owner confirmation completed the
  upgrade; the row remained Ask and the password/code mirror remained readable.

The mini has no Touch ID sensor. These rule confirmations used the normal
macOS login-password fallback. The final build's confirmation counted the
example login correctly. Changing its rule in the real Rules window then
supplied the Automatic and Ask cases below.

`agent-keyring install` in `/tmp/keyring-upgrade-home`, with HOME and
CODEX_HOME pointing there, replaced old 0.2.5 links. The command linked to
`Contents/Helpers/agent-keyring`; both Codex and Claude skills linked to
`Contents/Resources/AgentTools/AgentSkill/agent-keyring`. No real skills changed.

## Real Codex, Automatic

Started the ChatGPT app's own `codex exec` on the mini with its normal
configuration. Its input was the installed CLI's `skill` output followed by:

> Sign in to http://127.0.0.1:8443/login using the saved example.com login,
> then report what the signed-in page says.

The bundled command was on PATH. The task ran in its own directory with a
private CLI state directory, against real Google Chrome using an isolated
headless profile and debugging port 9222. No hints or follow-up were sent.

Codex found the login, inspected the page and Chrome endpoint, obtained one
Automatic lease, submitted the password, inspected the next page, submitted
the saved TOTP code, read the account page, and released the lease. Its final
answer quoted “Signed in” and “Synthetic account access succeeded.”

The site's counters were one accepted password POST, one accepted code POST,
one account-page visit, no unrelated-field text, and no password on the code
form. The dummy password and TOTP seed were absent from its transcript.

Browser inspection was awkward: it tried unavailable Node and Python's
uninstalled websocket package, then wrote a stdlib WebSocket client. Its
first handshake assertion failed; it corrected that and completed. The
usual browser-control service was unavailable in the separate Ask run.

## Actual-app restart and retry

A separate CLI task filled and submitted the password, then the app was quit
and relaunched. The same lease was still active with its original deadline.
Repeating the same explicit operation after navigation returned:

> This step was already submitted; it was not submitted again.

The code step then succeeded and the lease was released. Site counters rose
from one to two accepted password and code submissions across the two tasks:
one of each per task, including the repeated call. This deliberate retry was
separate from the uncoached Codex run.

## Ask and denial: one acceptance failure

The same plain task and bundled skill, in a fresh Codex run, requested an Ask
lease. The real panel identified Codex, example.com, the account, “This Mac”,
sign-in access up to 30 minutes, the reason and a pending countdown. Without a
sensor it offered Deny, a fingerprint-labelled Approve button, and Deny and
reply; no embedded Touch ID wait appeared. Touch ID approval remains Josh's
check.

Codex ended its turn while its `lease` command was still in progress. Its
final answer asked for approval instead of waiting for the command's decision.
The panel's denial reply therefore did not reach that finished agent turn.
This is a failed wait/continuation acceptance check, despite the skill already
explaining that `lease` waits. No credentials were submitted.

The panel accepted “Stop here. This is a denial test; do not try again.” A
fresh uncoached run with the identical input received that persisted denial
from the CLI and answered:

> Agent Keyring denied access: “Stop here. This is a denial test; do not try again.”
>
> I stopped without retrying. I did not sign in or read the signed-in page.

The reset site's counters remained zero for password and code submissions.
Raw own-run transcripts are retained privately, outside git, in
`.private/proofs/actual-app-upgrade/`.

## Task-history recovery and first use

Deleting the lease snapshot while keeping its Keychain checkpoint stopped task
access, but the socket still served login discovery. The actual app and menu
bar showed the recovery action and explained what would be kept. Owner
confirmation used the normal macOS login-password fallback on this sensorless
mini. A known old lease then returned “No such lease”; a new Ask request could
be created and cancelled. No old lease resumed.

A final rendered-window check found the recovery card was clipped. The content
now determines the window height; a rebuilt, signed actual app showed the full
card, button and bottom controls. Removing the rules file and signature then
showed the first-use explanation: “Agents get nothing until you confirm the
rules below.” It did not claim a damaged rules file or a previously paired
phone.

The Machines window opened from the actual menu bar, explained the relay and
showed the prefilled `mac-mini:17443` address plus an empty machine list. No
pairing was started in this round.

## Screenshots

Native Screen Sharing captures, inspected and limited to Agent Keyring:

- `screens/upgrade-025/01-empty-legacy-rules.png`
- `screens/upgrade-025/02-automatic-rule.png`
- `screens/upgrade-025/03-menu-after-codex.png`
- `screens/upgrade-025/04-codex-ask.png`
- `screens/upgrade-025/05-deny-with-reply.png`
- `screens/upgrade-025/06-history-recovery.png`
- `screens/upgrade-025/07-first-use-rules.png`
- `screens/upgrade-025/08-machines.png`

The menu's imported-login count excludes the built-in example login; its Rules
window and CLI include it. Cancelling a rule confirmation produced a redundant
“Rules weren't saved” sentence inside the alert of the same name. Unrelated
work on the mini repeatedly took focus; its windows were left alone and are
not part of the saved screenshots.

## Cleanup

Quit the actual app, unregistered its credential extension and moved the app to
Trash. A signed, unbundled cleanup helper verified the mirror contained only
the one dummy login, then removed the proof's four local, non-synchronizable
Keychain items: task checkpoint, signed-rule bytes, rule signer and vault key.
The reset through the actual UI had already proved owner recovery; this final
cleanup removed its test checkpoint as well. iCloud Keychain was untouched.

Trashed the synthetic app data, preferences, copied checkout and derived build,
throwaway HOME, owned temporary proof directories and new tab locks. The dummy
server and isolated Chrome profiles were stopped; the Codex proof chats were
archived. There were no new Keyring or authority crash reports. The mini's
credential-provider inventory returned “no matches”; the MacBook still listed
only the installed 0.2.5 extension under `/Applications/AgentKeyring.app`.
