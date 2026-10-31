# Actual 0.3.0 candidate inspection

Written by AI on 2026.10.31 by model gpt-6.1-sol.

Candidate: notarised 0.3.0, build 202610311328, copied unchanged from the
MacBook release folder to `/Applications/AgentKeyring.app` on the Mac mini.
No candidate was launched or installed on the MacBook. No passwords imported.

## Observed before the stop

- Gatekeeper accepted the candidate as Notarized Developer ID.
- Launch Services launched the real app. Its menu bar item appeared and opened
  the actual menu bar window. It served its production `agent.sock`.
- Its bundled CLI found exactly the built-in example.com login, under Ask.
- The actual Rules window listed that login. Rules needed confirmation, so no
  lease was requested and no rule was changed.
- Bundled `agent-keyring install`, run twice with a throwaway HOME, succeeded.
  It linked `.local/bin/agent-keyring` to `Contents/Helpers/agent-keyring`, and
  both `.codex/skills/agent-keyring` and `.claude/skills/agent-keyring` to
  `Contents/Resources/AgentTools/AgentSkill/agent-keyring` in the installed app.
  It touched no real agent skills.

The first-launch rules message said the saved rules could not be checked and
that the iPhone must be paired again. No production rules file or signature
existed. The production support directory contained only an empty vault
folder and a new empty lease snapshot written at this launch. The fixture
rules lived separately in `Data/r2-*/rules.json`; they did not occupy the
production `access-policies.json` path. This is incorrect first-use wording,
not evidence that the candidate read a fixture-signed production rules file.

The rules window otherwise displayed the one login cleanly. The AI rules
button was disabled; the empty table occupied most of the window. The compact
menu bar window showed no agent using a login and offered Rules and an
ellipsis menu. Ask approval, Automatic fill/retry/release, and Machines were
not reached before the orchestrator stopped the test to clean up old dialogs.

## Old errors and cleanup

A compact `AuthorityFixture quit unexpectedly` alert was visible on first
connection. A Problem Reporter details window identified AuthorityFixture
PID 11348, from the earlier proof at 05:48:55. These belonged to old fixture
runs, not the actual release app. Eleven old reports were found:

- `agent-keyring-authority-fixture`: 05:30:20 and 05:31:54 filenames.
- `AuthorityFixture`: 05:36:00; two each at 05:41:41 and 05:48:58;
  06:24:26 and 06:24:27.
- `RelayApproverFixture`: 06:12:56 and 06:21:14.

All report an EXC_BREAKPOINT / SIGTRAP in `swift_errorInMain`: an uncaught
error escaping the fixture entry point. The original Swift error is absent
from those reports, so its underlying cause cannot be established from them.
No release-app crash report was found. Sparkle's Downloader XPC appeared with
the running app; no Sparkle error dialog was observed.

The app was stopped, its extension unregistered, and the app moved to Trash.
All eleven reports, old crash-reporter preferences, six r2 proof roots, the
copied authority checkout/builds, owned build/proof logs, the transfer archive
and throwaway installation HOME were moved to Trash. `ps` and `lsof` showed
no non-fixture report held by Problem Reporter; terminating that process over
SSH closed all its windows, without clicking into unrelated active apps.
Final `pluginkit` output was `(no matches)`, and no app, fixture or Problem
Reporter process remained. Unrelated prompts and work were left alone.

The empty lease snapshot's data-protection Keychain checkpoint remains for
now. This exposed a separate recovery bug: deleting the app's lease files
leaves it refusing forever. The next change must provide an authenticated
reset rather than requiring someone to repair Keychain state manually.

## Screenshots

Cropped actual Screen Sharing captures, inspected after capture:

- `screens/actual-0.3.0-r3/01-menu-idle.png`
- `screens/actual-0.3.0-r3/02-old-fixture-crash.png`
- `screens/actual-0.3.0-r3/03-rules-unconfirmed.png`

Full-desktop captures were discarded because unrelated private work was
visible behind the app. No unrelated application data is part of this proof.
