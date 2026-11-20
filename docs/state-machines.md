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

## iPhone: first run

Code: `PhoneFirstRun` in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/PhoneFirstRun.swift`. `PhoneRelayBackend` sends it events and does what each state asks. Tests: `PhoneFirstRunTests`.

The machine follows the Paper board "First run", iPhone row. Each state is one picture on that board, and each event is one of its captions.

### States

| State | Screen |
|---|---|
| `welcome(startOnMac(longWait))` | "Agent Keyring" and "Start on your Mac", with Try a Practice Request. After two minutes, the iCloud paragraph is added. |
| `welcome(addComputer(mac))` | "Add a computer that stays on", with Try a Practice Request. |
| `welcome(approveOnMac(mac))` | "Approve on MacBook Pro", with "Waiting for MacBook Pro". |
| `welcome(denied(mac))` | "MacBook Pro didn't add this iPhone", with Ask Again. |
| `welcome(_, practising: true)` | The same screen, with the practice request open over it. |
| `notifications` | "Answer requests from your Lock Screen", with Continue. |
| `askingNotifications` | iOS's own question, over the same screen. |
| `notificationsOff` | "Notifications are off", with Open Settings and Continue Without Notifications. |
| `practiceWaiting(arrived)` | "Check that requests reach this iPhone", with "Waiting for the practice request". |
| `settingUpNotifications` | "Setting up notifications". |
| `practiceNotArrived` | "The practice request hasn't arrived", with Try Again. |
| `practice` | The practice request, open as a sheet. |
| `ready` | "Ready on this iPhone", with Done. The Apple Watch line shows only if a Watch is paired. |
| `finished` | The app's tabs. |

### What must always be true

- First run has one state. Every screen of first run, and every step the app takes in it, follows from that state alone.
- Only the steps after joining are saved. Before joining, the state starts afresh on each launch at `welcome(startOnMac(longWait: false))`.
- After a relaunch, `askingNotifications` becomes `notifications`. Any practice state becomes `practiceWaiting(arrived: false)`, and a new practice request is asked for. A device that joined on an earlier build, with no saved step, starts at `notifications`.
- Once the Mac refuses the iPhone, the look for the Mac makes no join request until Ask Again (`mayJoin`).
- The relay is asked for a practice request only in `practiceWaiting`, `settingUpNotifications` or `practice` (`wantsPractice`). A new request replaces the last.
- The practice request's end is taken from its own stream or from the work stream, whichever comes first. Losing either one cannot leave first run waiting.
- An event the table does not list for a state leaves the state unchanged. A repeated tap or a late answer from iOS therefore cannot move first run.
- Timers stay outside the machine and arrive as events: two minutes for `longWait`, and 30 seconds for `practiceTimedOut`.

### Transitions

| From | Event | To |
|---|---|---|
| any | `removed` (this iPhone left the list of devices) | `welcome(startOnMac(false))` |
| `welcome(denied)` | `noMac`, `macWithoutComputer`, `joinWaiting` | unchanged |
| `welcome(denied)` | `askAgain` | `welcome(startOnMac(false))` |
| `welcome` | `noMac(longWait)` | `welcome(startOnMac(longWait))` |
| `welcome` | `macWithoutComputer(mac)` | `welcome(addComputer(mac))` |
| `welcome` | `joinWaiting(mac)` | `welcome(approveOnMac(mac))` |
| `welcome` | `joinRefused(mac)` | `welcome(denied(mac))` |
| `welcome` | `joined` | `notifications` |
| `welcome(card, false)` | `tryPractice` | `welcome(card, true)` |
| `welcome(card, true)` | `closePractice` (approved with Face ID, or denied) | `welcome(card, false)` |
| `notifications` | `continueTapped` | `askingNotifications` |
| `notifications`, `askingNotifications`, `notificationsOff` | `notificationsAnswered(allowed: true)` | `practiceWaiting(false)` |
| `notifications`, `askingNotifications` | `notificationsAnswered(allowed: false)` | `notificationsOff` |
| `notificationsOff` | `continueWithoutNotifications` | `practiceWaiting(false)` |
| `practiceWaiting(false)` | `practiceArrived(pushExpected: true)` | `practiceWaiting(true)` |
| `practiceWaiting(false)` | `practiceArrived(pushExpected: false)` | `practice` |
| `settingUpNotifications`, `practiceNotArrived` | `practiceArrived` | `practice` |
| `practiceWaiting`, `settingUpNotifications`, `practiceNotArrived` | `practiceTapped` | `practice` |
| `practiceWaiting(true)` | `practiceTimedOut` | `practice` |
| `practiceWaiting(false)` | `practiceTimedOut(pushAddress: true)` | `practiceNotArrived` |
| `practiceWaiting(false)` | `practiceTimedOut(pushAddress: false)` | `settingUpNotifications` |
| `practiceNotArrived` | `tryAgain` | `practiceWaiting(false)` |
| `practiceWaiting`, `settingUpNotifications`, `practiceNotArrived`, `practice` | `practiceEnded` (approved, denied or unanswered) | `ready` |
| `ready` | `done` | `finished` |

What each state starts:
- Entering `practiceWaiting(false)` starts the 30-second timer. It also asks for the practice request if the relay already has this launch's push address. Otherwise the request is asked for when the address arrives.
- Entering `settingUpNotifications` asks for the practice request at once.

### Facts that are not first run's state

These are observations kept only for the self-test the relay stores. Nothing on a first-run screen reads them.
- `pushRegistered`: the relay has this launch's push address.
- `pushSeen`: a push has reached this iPhone. It is saved.
- `notificationsAllowed`: what iOS allows, read each time the app comes to the front.
- `openingWorks`: the opening key opened a sealed password.
- `practiceOutcome`: how the last practice request ended. Once approved it stays approved: the approval's own end a minute later is not a failure (test: `practiceApprovalLatches`).
- `watchPracticed`: Apple Watch's practice request has ended. It is saved, so the Watch gets one only.

Where the welcome card comes from: the look for the Mac reads the item the Mac leaves in iCloud Keychain every three seconds. No item is `noMac`. An item that names the Mac but has no relay and no secret is `macWithoutComputer`. A full invitation is joined; waiting is `joinWaiting` and a refusal is `joinRefused`, both with the Mac's name from the invitation.

### Reachable faults closed

1. **First run stuck with no button.** In the build before this one, the practice request's end was read only from its own stream, and a new request was asked for only at three moments: notifications allowed, push address registered, and 30 seconds with no address. Suppose that stream was lost while the app was away, for example because he answered from the Lock Screen. First run then stayed on the notifications screen with no button until the app was relaunched. Now the work stream also ends the practice, and coming back to the front asks again. Test: `practiceEndSeenOnTheWorkStream`, `relaunchMidPractice`.
2. **This iPhone removed while the app was open.** The work stream kept retrying with no relay to reach, and nothing looked for the Mac until the app was reopened. Now removal stops the stream and starts the look. Test: `removed`.
3. **Two practice requests after a relaunch.** A practice request still waiting from the last launch stayed beside the new one, and the sheet could show either. Now a new request removes the old one, and the latest is the one shown.

## Apple Watch: setup

Code: `WatchSetup` in `AgentKeyringPackage/Sources/AgentKeyringWatchCore/WatchSetup.swift`. `WatchLink.refreshSetup` works it out and `WatchHome` shows it. Test: `WatchSetupTests`.

The Watch's setup is worked out each time from facts the Watch reads about itself, and the app keeps none of them:
- its passcode;
- whether the iPhone has sent a signed list of devices;
- whether that list names this Watch;
- what watchOS allows for notifications;
- Apple's push address.

So the state cannot drift from those facts. The Watch works it out again when the app comes to the front, when the iPhone sends anything, when Apple gives the push address, and after Continue.

### States, in order of precedence

| State | When | Screen |
|---|---|---|
| `noPasscode` | no passcode | "Set a passcode" |
| `setUpIPhone` | no list of devices from the iPhone | "Set up your iPhone first" |
| `approveOnIPhone` | the list does not name this Watch | "Approve on your iPhone" |
| `notifications` | watchOS has not asked | "Answer on your wrist", with Continue, which raises watchOS's question |
| `notificationsOff` | notifications denied | "Notifications are off" |
| `settingUpNotifications` | no push address from Apple | "Setting up notifications" |
| `ready` | all of the above are in place | "Ready", or "In use" while an approval lasts |

### What must always be true

- watchOS asks about notifications only after the iPhone has added this Watch. Before this build, it asked the first time the app was opened.
- The Watch shows Ready once it is listed and allowed and has a push address. Its practice request then arrives as a notification over Ready: the iPhone asks the relay for it once the Watch's self-test says notifications are allowed and it has a push address, and asks only once (`watchPracticed`, saved on the iPhone). Ready does not wait for the practice, so a push that never comes cannot keep the Watch from Ready.

## Apple Watch: a request's card

Code: `RequestModel.Card` in `AgentKeyringWatch/RequestView.swift`; the answer in `WatchDelegate.answer` in `AgentKeyringWatch/WatchApp.swift`.

| State | Card |
|---|---|
| `opening` | nothing yet |
| `unreadable` | "Open Agent Keyring on your iPhone to see this request." The Watch has asked its iPhone for the list of devices. |
| `showing(request)` | who asks, the site, the account and the reason, each kept short so Apple's buttons follow on the first screen. An ended request shows its outcome instead. Its own practice request reads "Practice request: an agent wants" example.com. |

The answer is not part of the card. Approve, Deny and Deny and Explain are Apple's own notification buttons, one kind of button, and the system closes the notification when one is tapped. Approve needs the Watch unlocked on the wrist; Deny and Deny and Explain are marked destructive, so a Double Tap chooses Approve.

What must always be true:
- An answer goes only to the request whose notification it came from.
- If an answer does not reach the relay, one notification says so ("Not approved. Try on your iPhone.").
- The retry that reads the request again while the list arrives is cancelled when another notification takes the card, and when the card closes.

## Notifications on the iPhone and Apple Watch

- A request's notification goes when it is answered on this device, when this device learns it has ended (its work stream, or the relay's silent push for every outcome), and never comes back as a separate "Approved on your iPhone" notification. The silent push carries the request id at the top level (`"id"`) and no alert.
- Answering is the same whichever way it comes: the notification's Approve and the app's button can both run for one request; once this iPhone has answered it, or it has ended, a second answer returns without error. If the relay's reply is lost, the iPhone asks for the request and counts an outcome that matches its answer as sent. Test: `answeringTwice`.
- Tapping a notification opens its request even when the app was away and its stream has not yet sent it: the iPhone asks the relay for that request.
