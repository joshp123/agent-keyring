---
written_by: ai (Claude Opus 5.5, 2026-11-19). The Mac, relay and command sections are the core engineer's; the iPhone and Apple Watch engineer adds theirs.
---

# State machines

These are the places where Agent Keyring remembers where something is up to: their states, what must always be true, and what moves them. Each section names the code it describes. When the code changes, change the section with it.

What this file does not claim: that no other state exists. The sections below are the ones checked line by line against the code on 19 and 20 November 2026. Each ends with what was found that can actually go wrong, and what was done about it.

## Mac first run

Code: `AgentKeyringFeature/FirstRun.swift` (states and transitions, pure), `MirrorAppModel.send` (saves each move, reports it, bounces the Dock icon), `AgentKeyring/AgentKeyringApp.swift` `FirstRunHome` and `AgentKeyringScreenBackends/SetupScreens.swift` (draw it). One journey, the same list of steps on every device; its pages wait for the designer's drawing, so the windows today are interim.

One value, `FirstRun`, is saved in the app's settings: welcome, chooseDevices, `journey(devices, page)`, or finished. `devices` is what he chose (iPhone, Apple Watch, other computers), and the journey's pages are built from it (`FirstRun.pages(for:)`): practice, passwords, agents, then a computer that stays on if he chose any device, his iPhone, his Apple Watch, other computers, as chosen, then trying a request on each device, then Ready. Facts the world owns are read beside it and never copied into it:

- Touch ID can be used: `MacApprover.shared.state`.
- The passwords, and whether the only one is the sample.
- The first request from an agent on this Mac that he approved ("Try it now"): read from the leases.
- Whether this Mac reaches a computer that stays on, and which devices and computers have joined: the members list.
- Where each other device is in its own first run: its status report (`MacDevice.reports`: step, finished, checklist), which the relay tells the Mac about when it changes.
- The last practice request on each device (`MirrorAppModel.practiceResults`): sent, with Apple, arrived, approved, denied with his words, no answer, or failed. Not saved.

| State | Event | Next |
|---|---|---|
| welcome | Get Started | chooseDevices |
| chooseDevices | Continue with his choice | journey(choice, practice) |
| journey(practice) | approved with Touch ID | passwords (copyPasswords) |
| journey(practice) | Deny, with or without words | practiceDenied(reply); Try Again goes back |
| journey(copyPasswords) | his passwords arrive / Use a Sample Password | tellAgents(passwords(n) / sample) |
| journey(tellAgents(sample)), journey(ready) | Copy Your Own Passwords | copyPasswords |
| journey(any page with Continue or Skip) | Continue / Skip | the next page of his journey, passing over what is done: the computer that stays on if this Mac reaches one, the iPhone if it has finished its first run, the Apple Watch if it has joined |
| journey(stayingOn) | Touch ID connects to the announced computer | the next page |
| journey(stayingOn) | Use This Mac Alone | journey(this Mac alone, tryDevices) |
| journey(addPhone) | the iPhone reports its first run finished | the next page |
| journey(addWatch) | the Apple Watch joins | the next page |
| journey(ready) | Done | finished: the same window becomes Passwords and Devices |

An event with no row leaves the state as it is. A step that finishes while he is in another app (his passwords arriving, a device done, a computer connected) bounces the Dock icon once; no window is ever pushed in front. Every move sends this Mac's status report (its step, the journey's steps, finished), so the iPhone and Apple Watch show the same list and where the Mac is.

Devices opens the same windows in a sheet.

### Adding a device

`MacDevice.approveJoin`: after his Touch ID the device is in the members list at once, so it moves on in seconds. A new iPhone or Apple Watch then needs a copy of every password: this Mac opens its own copies with the same approval and seals them again for the device in batches of 50, off the main thread (`Resealer`), saving and uploading each batch. `MacDevice.filling` (the device, how many done, of how many) is set while that runs; the request panel stays up showing "<device> added. Copying your passwords to it: n of 547." and closes when it ends. The device counts its own copies on the relay (`Changes.sealed_for_you`) against the catalogue's count. If the app quits mid-way, the device has the batches already sent; adding the rest needs his Touch ID again (known and left alone).

### Practice requests from the Mac

Send Practice Request on another device chooses a request id and asks the relay for a practice request for that device (`MacDevice.practice(on:)`). The row shows each step as the relay reports it: sending, with Apple (the push was accepted), on the device (it said the request arrived), then the answer. A dropped connection is still waiting: the Mac asks again with the same id and rejoins it; the relay never makes a second one for a device while one waits. On this Mac the request panel shows the same practice request first run uses.

### The practice password

`PracticePassword`: practice.example.com, always there on this Mac for an agent's first try, even once his passwords are copied. It is not in his list or the catalogue and never goes to the relay; approving it takes Touch ID and opens nothing of his.

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
- **Adding his iPhone froze the Mac for about two minutes** (20 Nov): about four Secure Enclave operations for each of 547 passwords ran on the main thread before the iPhone was even added, and the iPhone gave up and asked again. The iPhone is now added first and its copies follow off the main thread, with progress.
- **"Add your Apple Watch" showed its steps after the Watch had joined from the iPhone**, and the Mac stood still while the iPhone finished: first run moved only on his buttons. Joins and other devices' finishes are now events, and the journey passes over what is done (`FirstRunTests`).
- **Done left him on nothing.** It closed the window; now the same window becomes Passwords and Devices.
- **A practice request was made again each time iOS cut the connection** (four for one iPhone on 20 Nov). It now has one id, is rejoined, and there is at most one waiting per device (`TestAPracticeRequestIsRejoinedNotMadeAgain`). The join connection has a heartbeat, so a waiting iPhone never times out.
- **"Set Up Agents on This Mac" changed his folders.** The button and `install`'s link switching are gone; the app gives him a note for his agents and changes nothing.
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
- **A denial holds the password off for that computer briefly, in one place for each kind of agent.** A minute after the first denial, five after a second in a row, fifteen after more; an approval, or an hour with no denial, starts again at a minute. The agent is told the time it may ask again and his reply word for word.
  - For an agent on another computer, the relay holds it off (`hold` in `store.go`: until, how many in a row, his words).
  - For an agent on the Mac, the Mac's lease store holds it off (`Suppression`). The Mac also tells the relay, so the iPhone and Apple Watch show the same outcome.
- **A device removed a moment ago cannot answer.** The relay checks an answer, and the asking computer's request, against the members list under the same lock that records it.
- **Only a request that newly waits is a notification Josh sees and hears.** Every outcome (answered, stopped, released, cancelled, no answer) is a silent push with the request's `id`, so the iPhone and Apple Watch take the notification away.
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

- **Lifting a hold-off is local.** If Josh lifts a hold-off on the Mac ("Let it ask again"), only the Mac's own hold-off goes. The relay's hold-off for the Mac stays for its minute or few. In that time a Mac agent's request is shown on the Mac but not offered to the iPhone and Apple Watch.

Found and fixed on 20 November, from Josh's run on his own devices (tests in `internal/relay/requests_test.go`, `DenialHoldTests`):

- **An answer from an Apple Watch added after the request was made never reached the Mac.** The Mac checked the answer against the members list it had when it connected, which did not list the Watch (`unknownSigner`). It now refreshes the list before it checks any answer, and hears of every new list on its connection (below).
- **Outcomes buzzed again.** The relay sent the same sounding alert for the answer and the release as for the request, so his Apple Watch showed old requests after he had answered them.
- **Thirty minutes after any denial** was too long for "not yet, fix this first".
- **A password with no website** (a server's, an app's) was ended the moment an agent asked, and the agent was told Josh had stopped it: the Mac narrowed the lease to the password's websites and found none (`DenialHoldTests.aPasswordWithNoWebsiteWaitsForJosh`).
- **A request cancelled at once could leave its alert behind**, when the push for "waiting" reached Apple after the silent one for "cancelled". One request's pushes now go one at a time, each with the state as it is when sent.

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

The presenter puts up one panel at a time, as one value: idle, showing an item, or closing an item (the outcome stays 2.5 seconds, a denial 10; the practice request goes at once, since first run's window says what happened). It always shows the first waiting item it can build; one whose request has gone is skipped, never left half-shown.

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

| notSetUp | Josh enters the address of a relay already running ("Connect"), then Touch ID | joined: this Mac the first device and the only computer, or, if the relay already lists this Mac's keys, that list as it stands |
| notSetUp | the relay at that address belongs to other devices | notSetUp, with the error |

| notSetUp | the computer that stays on announced itself; "Connect to Mac mini?", Touch ID | joined, the first members list carrying proof of the announced secret |

What must always be true: joined is reached only by his Touch ID. An empty relay takes its first members list only from someone who reached the relay's own computer: with proof of the one-time secret it gives only to a caller on its own address (our app there leaves it in iCloud Keychain, `RelayOffer`), or naming as the computer that stays on one that asked to join from that address (an agent's `setup-relay` and `enrol`). Nobody else on the network can take it first.

### Staying connected

While joined, the Mac holds one connection to the relay (`watch_work`). On it come the requests, and `Changes`: the members revision, the catalogue revision and the computers waiting to join, sent when the connection opens, whenever one of them changes, and at least every 30 seconds. The Mac takes a newer members list or catalogue when `Changes` names one. If nothing arrives for 75 seconds the connection is dead without having closed, and the Mac connects again. Nothing polls: the Mac used to ask for waiting joins every 3 seconds, 20 new connections a minute, and never refreshed the members list between connections.

Known and left alone: a restart of the Mac app in the middle of setup forgets it (settingUp is not saved). The agent's `enrol` then waits its ten minutes and stops with "no answer", and the agent runs `setup-relay` again. The connection, the members list and the running task are not part of this value: they follow the relay while joined.

## iPhone: first run

Code: `PhoneFirstRun` in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/PhoneFirstRun.swift`. `PhoneRelayBackend` sends it events and does what each state asks. Tests: `PhoneFirstRunTests`.

The machine follows the Paper board "iPhone and Apple Watch" (page "First run and the app"), iPhone first run. Each state is one screen on that board, and each event a button or a caption.

### States

| State | Screen |
|---|---|
| `welcome(startOnMac(longWait))` | "Welcome to Agent Keyring" and "Start on your Mac", with Try a Practice Request. After two minutes, the iCloud paragraph is added. |
| `welcome(addComputer(mac))` | "Add a computer that stays on", with Try a Practice Request. |
| `welcome(approveOnMac(mac))` | "Approve on MacBook Pro", with "Waiting for MacBook Pro". |
| `welcome(denied(mac))` | "MacBook Pro didn't add this iPhone", with Ask Again. |
| `welcome(_, practising: true)` | The same screen, with the practice request open over it. |
| `notifications` | "Turn on notifications", with Continue. |
| `askingNotifications` | iOS's own question, over the same screen. |
| `notificationsOff` | "Notifications are off", with Open Settings and Continue Without Notifications. |
| `practiceOffer` | "Try a request on this iPhone", with Send Practice Request. |
| `practiceWaiting(arrived)` | "Check that requests reach this iPhone", with "Waiting for the practice request". |
| `settingUpNotifications` | "Setting up notifications". |
| `practiceNotArrived` | "The practice request hasn't arrived", with Try Again. |
| `practice` | The practice request, open as a sheet. |
| `practiceResult(outcome)` | "You approved it" (or denied, or no answer), with Send Another and Continue. It stays until he goes on. |
| `addWatch` | "Add your Apple Watch", with Open the Watch App and Skip; Apple Watch's request to be added comes up over it. Only when a Watch is paired and not yet added. |
| `finished` | The app's tabs: Home, Passwords, Devices. |

### What must always be true

- First run has one state. Every screen of first run, and every step the app takes in it, follows from that state alone.
- Only the steps after joining are saved. Before joining, the state starts afresh on each launch at `welcome(startOnMac(longWait: false))`. A step saved by an earlier build that this build does not have reads as no step, never as broken saved state (test: `earlierBuildsFirstRunStillReads`).
- After a relaunch, `askingNotifications` becomes `notifications`, and any practice state, or its result, becomes `practiceOffer`: he sends a new one when he wants. A device that joined on an earlier build, with no saved step, starts at `notifications`.
- The practice request is sent only when he presses Send Practice Request or Send Another; nothing sends one by itself.
- Once the Mac refuses the iPhone, the look for the Mac makes no join request until Ask Again (`mayJoin`).
- The practice request's end is taken from its own stream or from the work stream, whichever comes first.
- An event the table does not list for a state leaves the state unchanged.
- Timers stay outside the machine and arrive as events: two minutes for `longWait`, and 30 seconds for `practiceTimedOut`.

### Transitions

| From | Event | To |
|---|---|---|
| any | `removed` (this iPhone left the list of devices) | `welcome(startOnMac(false))` |
| `welcome(denied)` | `noMac`, `macWithoutComputer`, `joinWaiting` | unchanged |
| `welcome(denied)` | `askAgain` | `welcome(startOnMac(false))` |
| `welcome` | `noMac(longWait)` | `welcome(startOnMac(longWait))` |
| `welcome` | `macWithoutComputer(mac)` (the Mac's item names it but has no relay) | `welcome(addComputer(mac))` |
| `welcome` | `joinWaiting(mac)` | `welcome(approveOnMac(mac))` |
| `welcome` | `joinRefused(mac)` | `welcome(denied(mac))` |
| `welcome` | `joined` | `notifications` |
| `welcome(card, false)` | `tryPractice` | `welcome(card, true)` |
| `welcome(card, true)` | `closePractice` (approved with Face ID, or denied) | `welcome(card, false)` |
| `notifications` | `continueTapped` | `askingNotifications` |
| `notifications`, `askingNotifications`, `notificationsOff` | `notificationsAnswered(allowed: true)` | `practiceOffer` |
| `notifications`, `askingNotifications` | `notificationsAnswered(allowed: false)` | `notificationsOff` |
| `notificationsOff` | `continueWithoutNotifications` | `practiceOffer` |
| `practiceOffer`, `practiceResult` | `sendPractice` (Send Practice Request, Send Another) | `practiceWaiting(false)` |
| `practiceWaiting(false)` | `practiceArrived(pushExpected: true)` | `practiceWaiting(true)` |
| `practiceWaiting(false)` | `practiceArrived(pushExpected: false)` | `practice` |
| `settingUpNotifications`, `practiceNotArrived` | `practiceArrived` | `practice` |
| `practiceWaiting`, `settingUpNotifications`, `practiceNotArrived` | `practiceTapped` | `practice` |
| `practiceWaiting(true)` | `practiceTimedOut` | `practice` |
| `practiceWaiting(false)` | `practiceTimedOut(pushAddress: true)` | `practiceNotArrived` |
| `practiceWaiting(false)` | `practiceTimedOut(pushAddress: false)` | `settingUpNotifications` |
| `practiceNotArrived` | `tryAgain` | `practiceWaiting(false)` |
| `practiceWaiting`, `settingUpNotifications`, `practiceNotArrived`, `practice` | `practiceEnded(outcome)` | `practiceResult(outcome)` |
| `practiceResult` | `continueAfterPractice(watchToAdd: true)` | `addWatch` |
| `practiceResult` | `continueAfterPractice(watchToAdd: false)` | `finished` |
| `addWatch` | `watchDone` (Skip, or Apple Watch added) | `finished` |

What each state starts:
- Entering `practiceWaiting(false)` starts the 30-second timer, and asks for the practice request if the relay already has this launch's push address; otherwise when the address arrives.
- Entering `settingUpNotifications` asks for the practice request at once.

## iPhone: every day

Code: `PhoneHomeView`, `PhoneLoginsView`, `PhoneDevicesView` and `PhoneSettingsView` in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/PhoneTabs.swift`. These screens hold no state of their own: each shows the snapshot, and each button sends one call.

- Home: Ready, or the one line that says what is wrong (the computer that stays on is offline; still connecting). Send Practice Request sends this iPhone a practice request, which then appears under "Needs your answer" like any request. Each request there has Deny… (the request sheet with the reply box and our microphone) and Approve in place. "In use" has Stop. "Earlier today" lists today's ended requests.
- Devices: Practice on Apple Watch's and the Mac's rows asks the relay for a practice request to that device (`test_request.for_device_key_id`); Remove on every row except this iPhone and the Mac's computer row, which its device row removes with it.

### Facts that are not first run's state

These are observations kept only for the self-test the relay stores. Nothing on a first-run screen reads them.
- `pushRegistered`: the relay has this launch's push address.
- `pushSeen`: a push has reached this iPhone. It is saved.
- `notificationsAllowed`: what iOS allows, read each time the app comes to the front.
- `openingWorks`: the opening key opened a sealed password.
- `practiceOutcome`: how the last practice request ended. Once approved it stays approved: the approval's own end a minute later is not a failure (test: `practiceApprovalLatches`).
- `watchPracticed`: Apple Watch's practice request has been made by the relay. It is saved, so the Watch gets one only.

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
- The Watch shows Ready once it is listed and allowed and has a push address. Its practice request then arrives as a notification over Ready: the iPhone asks the relay for it once the Watch's self-test says notifications are allowed and it has a push address, and asks only once (`watchPracticed`, saved on the iPhone as soon as the relay has made the request, with background time from iOS so that leaving the app at once does not cut the call short). Ready does not wait for the practice, so a push that never comes cannot keep the Watch from Ready.

## Apple Watch: a request's card

Code: `RequestModel.Card` in `AgentKeyringWatch/RequestView.swift`; the answer in `WatchDelegate.answer` in `AgentKeyringWatch/WatchApp.swift`.

| State | Card |
|---|---|
| `opening` | nothing yet |
| `unreadable` | "Open Agent Keyring on your iPhone to see this request." The Watch has asked its iPhone for the list of devices. |
| `showing(request)` | who asks, the site and the account, each on one line, then Deny and Approve, all on the first screen; then the agent's whole reason, once, read by scrolling; then Deny and Explain. An ended request shows its outcome in place of Deny and Approve. |
| `sending(request)` | the same, with the three buttons disabled |
| `answered(request, line)` | "Approved", "Denied", or "Not approved. Try on your iPhone."; the card closes 1.2 seconds later |

The three buttons are ours, one kind: Deny (red), Approve (green), Deny and Explain (grey), which opens watchOS's own text entry (dictation, Scribble or keyboard) inside the card. The notification category has no actions of Apple's, so Double Tap has nothing to choose and never answers.

What must always be true:
- An answer goes only to the request on screen, and only once: `respond` works only from `showing`.
- The retry that reads the request again while the list arrives is cancelled when another notification takes the card, and when the card closes.

## Notifications on the iPhone and Apple Watch

- A request's notification goes when it is answered on this device, when this device learns it has ended (its work stream, or the relay's silent push for every outcome), and never comes back as a separate "Approved on your iPhone" notification. The silent push carries the request id at the top level (`"id"`) and no alert.
- Answering is the same whichever way it comes: the notification's Approve and the app's button can both run for one request; once this iPhone has answered it, or it has ended, a second answer returns without error. If the relay's reply is lost, the iPhone asks for the request and counts an outcome that matches its answer as sent. Test: `answeringTwice`.
- Tapping a notification opens its request even when the app was away and its stream has not yet sent it: the iPhone asks the relay for that request.
