---
written_by: ai (Claude Opus 5.5, 2026-11-19). The Mac, relay and command sections are the core engineer's; the iPhone and Apple Watch engineer adds theirs.
---

# State machines

These are the places where Agent Keyring remembers where something is up to: their states, what must always be true, and what moves them. Each section names the code it describes. When the code changes, change the section with it.

What this file does not claim: that no other state exists. The sections below are the ones checked line by line against the code on 19 and 20 November 2026. Each ends with what was found that can actually go wrong, and what was done about it.

## Mac first run

Code: `AgentKeyringFeature/FirstRun.swift` (states and transitions, pure), `MirrorAppModel.send` (saves each move), `AgentKeyring/AgentKeyringApp.swift` `FirstRunHome` (draws it). Paper: page "First run and the app", board "First run". Each picture on the board is a state, and each caption is a transition.

One value, `FirstRun`, is saved in the app's settings. It holds only which screen he is on and what he did there. Facts the world owns are read beside it and never copied into it:

- Touch ID can be used: `MacApprover.shared.state` (ready, lid closed, or no fingerprint), read again when the screens change, the Mac wakes or the app becomes active. The first-run window, the request panel and the presenter all read this one value.
- The passwords: the store, and whether the only one is the sample.
- Whether the agents on this Mac are set up: `~/.local/bin/agent-keyring` resolves to this app's own command (`AgentsOnThisMac`). It is read from the link each time the window is drawn and when Continue is pressed, so the app's button, an agent's own `install`, `install --undo` and a Nix switch all show up. Nothing remembers it.
- Whether a computer that stays on exists: the members list.

| State | Screen | Event | Next |
|---|---|---|---|
| welcome | Welcome | Get Started | practice |
| practice | Try a practice request (the panel beside the window) | approved with Touch ID | copyPasswords |
| practice | | Deny, with or without words | practiceDenied(reply) |
| practiceDenied(reply) | You denied it | Try Again | practice |
| copyPasswords | Copy your passwords (see the copy below) | his passwords arrive and are sealed | setUpAgents(passwords(n)) |
| copyPasswords | | Use a Sample Password | setUpAgents(sample) |
| setUpAgents(copied) | N passwords copied, or 1 sample password added; Set up your agents | his own passwords arrive | setUpAgents(passwords(n)) |
| setUpAgents(sample) | | Copy Your Own Passwords | copyPasswords |
| setUpAgents | | Continue, only while the agents on this Mac are set up | ready |
| ready | Agent Keyring is ready (the sample box while the sample is the only password; the iPhone line depends on a computer that stays on) | Copy Your Own Passwords | copyPasswords |
| ready | | Done | finished |

An event the table has no row for leaves the state as it is.

"Set Up Agents on This Mac" runs the app's own `agent-keyring install` inside the sandbox, which may write only the command's and the agents' folders (`Config/AgentKeyring.entitlements`). While it runs, or after it fails, the click has its own short-lived value, `AgentsSetUpClick` (working, or failed with the command's words); it is never saved, and a failure never hides the links: if they show the agents set up, the tick shows.

### Copying from the Passwords app

Code: `PasswordsCopy` in `FirstRun.swift`, `MirrorCredentialImport.swift`. First run's "Copy your passwords" and the main window's Copy from Passwords are the same screens and the same value, `MirrorAppModel.passwordsCopy`. It is nil when no copy is open; first run draws nil as the three steps, and the main window shows its list. It is not saved.

| State | Event | Next |
|---|---|---|
| nil or steps | Open Passwords (Copy Again in the main window) | waiting |
| waiting | five minutes with nothing | noneArrived |
| steps, waiting or noneArrived | "Agent Keyring isn't in the list?" | allowExport(asking: false) |
| allowExport(false) | Continue: macOS asks to turn on AutoFill | allowExport(true) |
| allowExport(true) | Turn On | steps |
| allowExport(true) | Not Now, then macOS's 10 seconds | allowExport(false) |
| any | the export starts arriving | copying |
| copying | sealed and saved | nil |
| copying | failed | steps, with the error |
| any | Use a Sample Password, or Cancel in the main window | nil |

What must always be true:

- **Exactly one screen.** The window is `FirstRun`, `passwordsCopy` and the facts above; nothing else chooses it.
- **The practice request exists only in `practice`, and only while Touch ID is ready.** When the lid is closed or no fingerprint is enrolled, the window says "Open the lid" or "Add a fingerprint" in its place.
- **The request panel never covers the window that explains it.** It goes to the right of Agent Keyring's window, else to its left, else the window moves to the screen's left edge (`RequestPanel.frame`, tested on 1728- and 1280-point screens).
- **A restart never strands him.** Every state resumes as saved, and a copy starts again from the steps. If a later build cannot read the saved state, first run starts at welcome. A Mac that finished first run before this state was saved opens as finished.
- **A fresh container is a new install.** On its first launch the app deletes what an earlier install left in the keychain (its relay and members, its rules, the name it left for the iPhone in iCloud Keychain) and keeps this Mac's keys (`MirrorAppModel.forgetPreviousInstall`).
- **The sample is an ordinary Ask password.** His first copy from Passwords removes it from the list, the sealed store and the relay.

Found and fixed (tests in `FirstRunTests`, `SamplePasswordTests`, and `TestABlockedLoginHasNoCopyOnTheRelay` in `internal/relay`):

- **A late timer.** The five-minute timer moves the copy on only from `waiting`, so it cannot fire after the passwords arrived.
- **A remembered "set up" that went stale.** The first build saved a flag when `install` ran; `install --undo` or a Nix switch left it saying yes. The links are now the only record.
- **The ten flags first run replaced** (`isImporting`, `awaitingExport`, `exportTimedOut`, `showsAutoFillHelp`, `providerState`, `canAskAgain`, `selfTest`, `firstRunFinished`, the window's own `lidClosed` and `needsFingerprint`). Choosing the sample also closes an open copy, so the main window never opens later on a copy he abandoned.

## The lease, across the Mac, the relay and the command

Code: `internal/relay/requests.go` (the relay's record), `internal/remote/exchange.go` (the command on another computer), `AgentKeyringFeature/CredentialLeaseStore.swift` with `MirrorAgentRequests.swift` (an agent on the Mac), `cmd/agent-keyring/main.go` `leaseState` (the word `status` prints).

The relay's record of one request:

| Relay state | Reached by | Who moves it on | `status` on the asking computer |
|---|---|---|---|
| WAITING | a request signed by the computer that asks | a device answers; the agent stops asking; 10 minutes pass | pending |
| APPROVED | a device's signed answer; the Mac answering its own agent (`answered_here`, only from a Mac device); an Automatic request the list and members allow | the agent releases; a device presses Stop; 30 minutes pass | active |
| DENIED | a device's answer, signed or plain; the Mac denying its own agent | nothing: it ends there | denied (with the signed words, if any) |
| UNANSWERED | 10 minutes with no answer | nothing | unanswered |
| CANCELLED | the agent stopped asking while it waited | nothing | cancelled |
| ENDED | released by the agent, Stop on a device (`ended_by` set), or 30 minutes | nothing | released, stopped by Josh, or expired |

What must always be true:

- **Every answer is over the asking computer's signed bytes.** The command checks an approval and a denial's words against the request it saved before sending. The relay cannot answer one request with another's approval.
- **A device's approval keeps working while the relay is down, until its 30 minutes end.** The command saves it on first sight, and deletes it when the relay says the request ended. This is so a relay restart does not break an approval he already gave.
- **A denial holds the password off for that computer for 30 minutes, in one place for each kind of agent.**
  - For an agent on another computer, the relay holds it off.
  - For an agent on the Mac, the Mac's lease store holds it off. The Mac also tells the relay, so the iPhone and Apple Watch show the same outcome.
- **The Mac never waits for the relay.** A Mac agent's request is shown on the Mac at once, and also offered to the iPhone and Apple Watch when the relay can be reached. The first answer wins. The Mac's lease store is the record for that agent; the relay's copy follows it:
  - approved or denied on the Mac: `answered_here`;
  - released: `end`;
  - Stop on a device: the Mac revokes the lease.

Found and fixed this week, each by a run that reached it:

- **Stop on a device never reached the Mac** (125552b).
- **Any computer could mark its own request "approved on your Mac"** (125552b).
- **A Mac lease approved on the iPhone** stayed "in use" on the iPhone after the agent released it (7502427).
- **Stop on the iPhone** showed on the Mac's lease as "released", not "stopped by Josh" (23f8b13).
- **An Automatic use** ran on the computer alone and was invisible. It is now a relay record like any other, so Stop ends it (e38bd05).

Known and left alone:

- **Lifting a hold-off is local.** If Josh lifts a hold-off on the Mac ("Let it ask again"), only the Mac's own hold-off goes. The relay's hold-off for the Mac stays for its 30 minutes. In that time a Mac agent's request is shown on the Mac but not offered to the iPhone and Apple Watch.

## The Mac's approval panel

Code: `AgentKeyringApprovalUI/Mac/MacApprovalPanel.swift` `MacApprovalModel`, and `AgentKeyring/ApprovalPresenter.swift`.

The request's state belongs to the backend: only its updates and its answers to Approve, Deny and "Let it ask again" change it. Beside it the panel holds one value, `Local`, for what Josh has started there:

| Local | Reached by | Next |
|---|---|---|
| idle | the panel appears | authenticating (Approve), sending(deny) (Deny) |
| authenticating | the click on the green button: macOS's dialog is up | sending(approve) when he confirms; idle on Cancel; failed |
| sending(choice) | his answer is on its way; the panel shows it as sending even if an update says the request still waits | idle (approved), denied, failed |
| denied | the backend took his denial | lifted ("Let it ask again") |
| lifted | the backend lifted the hold-off | |
| failed(message) | what he started didn't go through | authenticating, sending(deny) |

What must always be true:

- **An answer from elsewhere closes the dialog.** If the request stops waiting while macOS's dialog is up, `followUpdates` cancels the dialog, and its end is a cancel, not an error.
- **A Deny clicked while the dialog is up wins.** The dialog's own end changes `Local` only while it is still `authenticating` or `sending(approve)`.
- **A touch that lands after another device answered releases nothing.** For an agent on the Mac, the lease store approves only a pending lease. For another computer, the relay refuses a second answer.

The presenter puts up one panel at a time, as one value: idle, showing an item, or closing an item (the outcome stays 2.5 seconds, a denial 10). It always shows the first waiting item it can build; one whose request has gone is skipped, never left half-shown.

Found and fixed: the panel used to write "sending" into the request's own state, so an update arriving mid-send had to be skipped by hand, and the presenter kept six fields (`shownItem`, `shownRequest`, `question`, `showing`, `closingAfterAnswer`, `needsFingerprint`); a request that vanished between being chosen and being shown left the presenter pointing at the previous one. Test: `anUpdateWhileHisDenialIsSentDoesNotUndoIt`.

## Mac relay setup

Code: `AgentKeyringFeature/MacDevice.swift`.

One value, `Lifecycle`: notSetUp, settingUp(Setup), or joined(Saved). `Setup` carries the relay's address, its TLS key as first seen, the invitation's secret, the agent and its reason, and the computer that stays on once its join proves the invitation. `Saved` lives in the keychain.

| Lifecycle | Event | Next |
|---|---|---|
| notSetUp | an agent runs `setup-relay` | settingUp |
| settingUp | Josh denies the computer, or two computers prove one invitation | notSetUp |
| settingUp | Touch ID on "add Mac mini", and the relay takes the members list | joined |
| settingUp | Touch ID, but the relay refuses the list | settingUp (he can approve again) |

What must always be true: joined is reached only by his Touch ID on the computer that stays on.

Known and left alone: a restart of the Mac app in the middle of setup forgets it (settingUp is not saved). The agent's `enrol` then waits its ten minutes and stops with "no answer", and the agent runs `setup-relay` again. The connection, the members list and the running task are not part of this value: they follow the relay while joined.

## iPhone and Apple Watch

To be written by the iPhone and Apple Watch engineer: the iPhone's first run and the Apple Watch's request screen.
