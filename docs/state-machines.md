---
written_by: ai (Claude Opus 5.5, 2026-11-19). The Mac, relay and command sections are the core engineer's; the iPhone and Apple Watch engineer adds theirs.
---

# State machines

These are the places where Agent Keyring remembers where something is up to: their states, what must always be true, and what moves them. Each section names the code it describes. When the code changes, change the section with it.

What this file does not claim: that no other state exists. The sections below are the ones checked line by line against the code on 19 November 2026. Each ends with what was found that can actually go wrong, and what was done about it.

## Mac first run

Code: `AgentKeyringFeature/FirstRun.swift` (states and transitions, pure), `MirrorAppModel.send` (saves each move), `AgentKeyring/AgentKeyringApp.swift` `FirstRunHome` (draws it). Paper: page "First run and the app", board "First run". Each picture on the board is a state, and each caption is a transition.

One value, `FirstRun`, is saved in the app's settings. It holds only which screen he is on and what he did there. Facts the world owns are read beside it and never copied into it:

- Touch ID can be used: the lid, and whether a fingerprint is enrolled.
- The passwords: the store, and whether the only one is the sample.
- The computers that have joined or are waiting: the members list and its joins.
- Whether the practice request ever passed: its tested date.
- Whether `agent-keyring install` has run on this Mac: a saved flag.

| State | Screen | Event | Next |
|---|---|---|---|
| welcome | Welcome | Get Started | practice |
| practice | Try a practice request (the panel beside the pointer) | approved with Touch ID | copyPasswords(notOpened) |
| practice | | Deny, with or without words | practiceDenied(reply) |
| practiceDenied(reply) | You denied it | Try Again | practice |
| copyPasswords(notOpened, waiting, noneArrived) | Copy your passwords | Open Passwords | copyPasswords(waiting) |
| copyPasswords(waiting) | Waiting for your passwords… | five minutes pass | copyPasswords(noneArrived) |
| copyPasswords(any) | | the export starts arriving | copying |
| copyPasswords(any) | | Use a Sample Password | setUpAgents(sample) |
| copying | Copying your passwords… | sealed and saved | setUpAgents(passwords(n)) |
| copying | | failed | copyPasswords(notOpened), with the error |
| setUpAgents(copied, messageCopied) | N passwords copied / 1 sample password added; Set up your agents | Copy Message | setUpAgents(copied, true) |
| setUpAgents | | `install` ran (now, or before he got here) | computers |
| setUpAgents | | his own copy arrives | setUpAgents(passwords(n)) |
| setUpAgents | | Do This Later | almostReady |
| computers | Set up your agents: each computer, added or waiting | Continue | ready |
| ready / almostReady | Agent Keyring is ready / almost ready | Done | finished |

An event the table has no row for leaves the state as it is.

What must always be true:

- **Exactly one screen.** The window is `FirstRun` plus the facts above; nothing else chooses it.
- **The practice request beside the pointer exists only in `practice`.** It also needs Touch ID to be usable. When it is not (the lid is closed, or no fingerprint is enrolled), the window says "Open the lid" or "Add a fingerprint" in its place. The window and the panel's presenter read the same two facts.
- **A restart never strands him.** `copying` and every `copyPasswords` resume as `copyPasswords(notOpened)`, because the app no longer runs that copy or that timer. Every other state resumes as saved.
  - If a later build cannot read the saved state, first run starts at welcome.
  - A Mac that finished first run before this state was saved opens as finished.
- **The sample is an ordinary Ask password.** His first copy from Passwords removes it from the list, the sealed store and the relay. The relay keeps no copy of a login that is no longer listed.

Found and fixed (tests in `FirstRunTests`, `SamplePasswordTests`, and `TestABlockedLoginHasNoCopyOnTheRelay` in `internal/relay`):

- **A late timer.** The five-minute timer used to set a flag of its own, so it could fire after the passwords had arrived. Now it is an event that only `copyPasswords(waiting)` takes.
- **The ten flags it replaces.** They were `isImporting`, `awaitingExport`, `exportTimedOut`, `showsAutoFillHelp`, `providerState`, `canAskAgain`, `selfTest`, `firstRunFinished`, and the window's own `lidClosed` and `needsFingerprint`. Together they could say "copying" and "timed out" at once, and a Mac that copied its passwords before the practice request would skip it.
- **An agent quicker than Josh.** `install` reporting before he reached "Set up your agents" would have left that screen waiting forever. Entering the screen now checks the saved flag.

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

Code: `AgentKeyringApprovalUI/Mac/MacApprovalPanel.swift` `MacApprovalModel`.

The panel holds `request.state`, which the backend's updates own, beside four values of its own:

- `isWaitingForTouch`: from the click on Approve until macOS's dialog returns.
- `approval`: the task running that dialog.
- `deniedHere` and `liftedHere`: Josh's own Deny and "Let it ask again", until the backend reports them.

What must always be true:

- **An answer from elsewhere closes the dialog.** If the request stops waiting while macOS's Touch ID dialog is up, `followUpdates` cancels the dialog, and the task ends as a cancel, not an error.
- **A touch that lands after another device answered releases nothing.** For an agent on the Mac, the lease store approves only a pending lease. For another computer, the relay refuses a second answer.

Checked, no change: no path was found where the four values disagree with `request.state` in a way he can see. They are reset by the task's `defer`, and by the state updates, which always win.

## Mac relay setup

Code: `AgentKeyringFeature/MacDevice.swift`.

The setup is held in parallel values:

- `setup`, `setupPin`, `setupSecret` and `setupWatch` live in memory, from `setup-relay` until he approves the computer that stays on;
- `saved` lives in the keychain, from then on.

What must always be true: `saved` exists only once he has approved the computer that stays on with Touch ID.

Known and left alone: a restart of the Mac app in the middle of setup forgets the setup. The agent's `enrol` on the computer that stays on then waits its ten minutes and stops with "no answer", and the agent runs `setup-relay` again. Folding the four values into one would make the code no smaller, so they stay.

## iPhone and Apple Watch

To be written by the iPhone and Apple Watch engineer: the iPhone's first run and the Apple Watch's request screen.
