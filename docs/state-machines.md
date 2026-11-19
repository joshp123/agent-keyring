<!-- Written by AI on 2026.11.19 by model Claude Opus 5.5 (the iPhone and Apple Watch sections). -->

# State machines

The app's state machines, each with its states, what must always be true, and its transitions. Each section names the code that holds the machine.

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
- `practiceOutcome`: how the last practice request ended.

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
- The Watch shows Ready once it is listed and allowed and has a push address. The board puts a practice request to the Watch before Ready. That waits for the relay to send one to the Watch.

## Apple Watch: a request's card

Code: `RequestModel.Card` in `AgentKeyringWatch/RequestView.swift`.

| State | Card |
|---|---|
| `opening` | nothing yet |
| `unreadable` | "Open Agent Keyring on your iPhone to see this request." The Watch has asked its iPhone for the list of devices. |
| `showing(request)` | the request, with Deny and Approve |
| `sending(request)` | the same request, with the buttons disabled |
| `answered(request, line)` | the same request and "Approved" or "Denied". The card closes 1.2 seconds later. |

What must always be true:
- An answer goes only to the request on screen.
- Only one answer is sent: `respond` works only from `showing`.
- The retry that reads the request again while the list arrives is cancelled when another notification takes the card, and when the card closes. Before this build it ran on for ten seconds and could put an older request back on the card.
