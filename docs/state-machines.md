---
written_by: ai (Claude Opus 5.5, 2026-11-19). The Mac, relay and command sections are the core engineer's; the iPhone and Apple Watch engineer adds theirs.
---

# State machines

These are the places where Agent Keyring remembers where something is up to: their states, what must always be true, and what moves them. Each section names the code it describes. When the code changes, change the section with it.

What this file does not claim: that no other state exists. The sections below are the ones checked line by line against the code on 19 and 20 November 2026. Each ends with what was found that can actually go wrong, and what was done about it.

## Mac first run

Code: `AgentKeyringFeature/FirstRun.swift` (states and transitions, pure), `MirrorAppModel.send` (saves each move, bounces the Dock icon), `AgentKeyring/AgentKeyringApp.swift` `FirstRunHome` and `AgentKeyringScreenBackends/SetupScreens.swift` (draw it). One journey, the same list of steps on every device; its pages wait for the designer's drawing, so the windows today are interim.

One value, `FirstRun`, is saved in the app's settings: welcome, chooseDevices, `journey(devices, page)`, or finished. `devices` is what he chose (iPhone, Apple Watch, other computers), and the journey's pages are built from it (`FirstRun.pages(for:)`): practice, passwords, agents, then a computer that stays on if he chose any device (always passed over since 21 November: no computer needs to stay on), his iPhone, his Apple Watch, other computers, as chosen, then trying a request on each device, then Ready. Facts the world owns are read beside it and never copied into it:

- Touch ID can be used: `MacApprover.shared.state`.
- The passwords, and whether the only one is the test password.
- The first request from an agent on this Mac that he approved ("Try it now"): read from the leases.
- Which devices and computers have joined: the members list. The iPhone counts as done once it is listed and its copies are made (`MacDevice.filling` no longer names it); Apple Watch once it is listed. Devices send no status report any more.
- The last practice request on each device (`MirrorAppModel.practiceResults`): sent, with Apple, arrived, approved, denied with his words, no answer, or failed. Not saved.

| State | Event | Next |
|---|---|---|
| welcome | Get Started | chooseDevices |
| chooseDevices | Continue with his choice | journey(choice, practice) |
| journey(practice) | approved with Touch ID | passwords (copyPasswords) |
| journey(practice) | Deny, with or without words | practiceDenied(reply); Try Again goes back |
| journey(copyPasswords) | his passwords arrive / Use the Test Password Only | tellAgents(passwords(n) / sample) |
| journey(tellAgents(sample)), journey(ready) | Copy Your Own Passwords | copyPasswords |
| journey(any page with Continue or Skip) | Continue / Skip | the next page of his journey, passing over what is done: the computer that stays on (always), the iPhone once it is added and filled, the Apple Watch once it is added |
| journey(stayingOn), saved by an earlier build | the app starts | the page after it |
| journey(addPhone) | the iPhone is added and its copies made | the next page |
| journey(addWatch) | the Apple Watch is added | the next page |
| journey(ready) | Done | finished: the same window becomes Passwords and Devices |

An event with no row leaves the state as it is. A step that finishes while he is in another app (his passwords arriving, a device done) bounces the Dock icon once; no window is ever pushed in front.

Devices opens the same windows in a sheet.

### Adding a device

`MacDevice.approveJoin`: after his Touch ID the device is in the members list at once, so it moves on in seconds. A new iPhone or Apple Watch then needs a copy of every password: this Mac opens its own copies with the same approval and seals them again for the device in batches of 50, off the main thread (`Resealer`), saving each batch; the iPhone hears from a silent push that its copies changed and fetches its bundle. `MacDevice.filling` (the device, how many done, of how many) is set while that runs; the request panel stays up showing "<device> added. Copying your passwords to it: n of 547." and closes when it ends. If the app quits mid-way, the device has the batches already saved; adding the rest needs his Touch ID again (known and left alone). Joining itself is "Joining the Mac", below.

### Practice requests from the Mac

Send Practice Request on another device makes a practice request for that device and pushes it (`MacDevice.practice(on:)`; "The Mac's own requests", below). The row shows each step: sending, with Apple (Apple accepted the push), on the device (it said the request arrived), then the answer. While one waits for a device, a second is never made. A device may ask the Mac for one itself (POST /v2/practice); one for this Mac shows the practice panel here. On this Mac the request panel shows the same practice request first run uses.

### The test password

`MirrorItem.testPassword`: example.com, you@example.com, password "hello". The first copy brings it (`MirrorAppModel.importBatch`) and every later copy keeps it, as it keeps any password missing from an export; "Use the Test Password Only" is a copy of nothing. It is an ordinary Ask password: in his list and the catalogue like any other, so an agent on any of his computers can try the whole route with a secret that does not matter.

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
| any | Use the Test Password Only, or Cancel in the main window | nil |

What must always be true:

- **Exactly one screen.** The window is `FirstRun`, `passwordsCopy` and the facts above; nothing else chooses it.
- **The practice request exists only in `practice`, and only while Touch ID is ready.** When the lid is closed or no fingerprint is enrolled, the window says "Open the lid" or "Add a fingerprint" in its place.
- **The request panel never covers the window that explains it.** It goes to the right of Agent Keyring's window, else to its left, else the window moves to the screen's left edge (`RequestPanel.frame`, tested on 1728- and 1280-point screens).
- **A restart never strands him.** Every state resumes as saved, and a copy starts again from the steps. If a later build cannot read the saved state, first run starts at welcome. A Mac that finished first run before this state was saved opens as finished.
- **A fresh container is a new install.** On its first launch the app deletes what an earlier install left in the keychain (its lists, members and push registrations, its rules, the invitation it left for the iPhone in iCloud Keychain) and keeps this Mac's keys (`MirrorAppModel.forgetPreviousInstall`).
- **There is always exactly one test password.** A copy from Passwords keeps it; nothing removes it.
- **A copy from Passwords replaces the list, one entry for one entry** (`SnapshotMerger`). The Passwords app gives every item new ids on each export, so an entry is matched by those ids first and then by its sites, account names and title, one to one, keeping the earlier entry's id and so its rule. When two earlier entries fit one, the one with a rule he set is kept. An entry the copy leaves out goes from the list, and the next Touch ID that signs the catalogue takes its copies out of every bundle; the test password stays.

Found and fixed (tests in `FirstRunTests`, and `TestABlockedLoginHasNoCopyOnTheRelay` in `internal/relay`):

- **A second copy from Passwords doubled the list** (20 Nov): every item arrived with new ids, so nothing matched and the earlier entries were all kept. The next copy goes back to one of each, keeping the entries his rules are on (`SnapshotMergerTests`).
- **A late timer.** The five-minute timer moves the copy on only from `waiting`, so it cannot fire after the passwords arrived.
- **Adding his iPhone froze the Mac for about two minutes** (20 Nov): about four Secure Enclave operations for each of 547 passwords ran on the main thread before the iPhone was even added, and the iPhone gave up and asked again. The iPhone is now added first and its copies follow off the main thread, with progress.
- **"Add your Apple Watch" showed its steps after the Watch had joined from the iPhone**, and the Mac stood still while the iPhone finished: first run moved only on his buttons. Joins and other devices' finishes are now events, and the journey passes over what is done (`FirstRunTests`).
- **Done left him on nothing.** It closed the window; now the same window becomes Passwords and Devices.
- **A practice request was made again each time iOS cut the connection** (four for one iPhone on 20 Nov). It now has one id, is rejoined, and there is at most one waiting per device (`TestAPracticeRequestIsRejoinedNotMadeAgain`). The join connection has a heartbeat, so a waiting iPhone never times out.
- **"Set Up Agents on This Mac" changed his folders.** The button and `install`'s link switching are gone; the app gives him a note for his agents and changes nothing.
- **The ten flags first run replaced** (`isImporting`, `awaitingExport`, `exportTimedOut`, `showsAutoFillHelp`, `providerState`, `canAskAgain`, `selfTest`, `firstRunFinished`, the window's own `lidClosed` and `needsFingerprint`). Choosing the test password only also closes an open copy, so the main window never opens later on a copy he abandoned.

## The lease, across the Mac, the relay and the command

The relay is how the installed apps work until Josh's test of the direct design; the command no longer uses it (next section). This section goes when the relay does.

Code: `internal/relay/requests.go` (the relay's record), `AgentKeyringFeature/CredentialLeaseStore.swift` with `MirrorAgentRequests.swift` (an agent on the Mac), `cmd/agent-keyring/main.go` `leaseState` (the word `status` prints).

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
  - For an agent on the Mac, the Mac's lease store holds it off (`Suppression`), whichever device denied ("The Mac's own requests", below).
- **A device removed a moment ago cannot answer.** The relay checks an answer, and the asking computer's request, against the members list under the same lock that records it.
- **Only a request that newly waits is a notification Josh sees and hears.** Every outcome (answered, stopped, released, cancelled, no answer) is a silent push with the request's `id`, so the iPhone and Apple Watch take the notification away.
- **The Mac never waits for the iPhone or Apple Watch.** A Mac agent's request is shown on the Mac at once, and also pushed to them when it can be ("The Mac's own requests", below). The first answer wins, in the Mac's lease store.

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

## A request from a computer without the app, with no relay

Written by AI on 2026.11.21 by model claude opus 5.5. Code: `internal/remote/exchange.go` (asking, settling, release, opening), `internal/remote/answers.go` (what the door takes), `internal/remote/push.go`, `internal/door/door.go` (holding the door). Tests: `TestAnAgentAsksAndJoshAnswersFromHisIPhoneOrWatch` and `TestJoiningTheMacGoesWrong` in `e2e/e2e_test.go`.

The computer an agent asks from owns its request. The record is one `agentkeyring.v2.Lease` for each request (`ExpectedRequest.lease` in the command's state file, `internal/clientstate/state.proto`), changed only under the state file's lock, by whichever of the computer's command processes sees the event.

| State | Reached by | Who moves it on | `status` |
|---|---|---|---|
| WAITING | `lease`: the request is signed with this computer's door (`answer_address`, its Tailscale IP and port 17446) and TLS key, saved, then pushed to each device with a push address | a device's answer at the door; `release`; `answer_by` passing | pending |
| APPROVED | a device's signed approval that checks against the newest Members held and opens with this computer's receiving key; or, Automatic, at once: the catalogue says Automatic, Members allows this computer, and its own copy checks | `release`; Stop at the door; 30 minutes | active |
| DENIED | a signed denial (his words kept only as signed), or a plain denial naming the request id | nothing | denied |
| UNANSWERED | `answer_by` passed while it waited | nothing | unanswered |
| CANCELLED | `release` while it waited | nothing | cancelled |
| ENDED | `release`; Stop (`ended_by` set); 30 minutes | nothing | released, stopped by Josh, or expired |

While it waits, `pushed_unix_seconds` is set when Apple first takes a visible push, and `arrived_unix_seconds` and `arrived_on` on the first `POST /v2/arrived`.

What must always be true:

- **Whoever moves a request on tells the devices, once.** The door's holder for an answer or a Stop; the process that notices `answer_by` or the 30 minutes pass; `release` for the agent. Each sends the silent outcome push to every device. An Automatic use gets a silent push when it starts, so the devices can show it in use and stop it.
- **The first answer wins.** Answers are taken under the state file's lock. A later one gets 200 with the Lease that already ended the request.
- **A device Josh removed cannot answer.** Before checking an answer or a Stop, the door asks the Mac for newer lists, for half a second; with no reply it checks against what it holds. A removed device gets 403 with a sentence.
- **One task, one request.** The same request id, or the same task asking for the same password while its request waits or its approval lasts, rejoins that request; nothing is pushed again.
- **A denial holds the password off for this computer**, as on the relay: 1 minute, then 5, then 15 in a row; an approval, or an hour with no denial, starts again (`State.holds`).
- **A shut Mac never holds an agent up.** Every contact with the Mac's door before asking waits at most 500 ms, then uses what this computer holds. An Automatic copy used that way is logged as `automatic used without the Mac`.
- **Only Tailscale.** Every connection goes to a Tailscale IP; a name, or an address off the tailnet, is refused with a sentence. A computer with no Tailscale address says so when it enrols or asks.

## The door, shared by a computer's command processes

Written by AI on 2026.11.21 by model claude opus 5.5. Code: `door.Hold` in `internal/door/door.go`, started once per process by `remote.Client.holdDoor` and let go by `remote.Close`.

Each command process that runs for a request (`lease`, `status`, `read`, `release`, `fill`) is in one of these states:

| State | Event | Next |
|---|---|---|
| trying | binding this computer's Tailscale IP, port 17446, succeeds | holding |
| trying | another process holds the port, or Tailscale has no address | trying, again a second later |
| holding | an answer, arrival or Stop arrives, for any request of this computer | holding: it is written to the state file |
| trying or holding | the process's work is done | letting go: no new connections; answers being taken are saved and their outcome pushed |
| letting go | done | gone; a trying process binds within a second |

Each waiting process reads its own request's state from the state file every 200 ms, so it sees an answer whichever process took it. A device whose post cannot connect retries for 30 seconds, so an answer during a hand-over reaches the next holder (tested: two waiting `lease` processes, the holder's request approved and the process gone, the other then answered).

Known and left alone:

- **No process, no door.** After `lease` prints its id, or with `lease --no-wait`, nothing holds the door until another command runs for a request. A device's answer or Stop then fails after 30 seconds; for Stop, the device says the access ends by itself at its time. The approval itself still ends at its 30 minutes.
- **A list signed by a device this computer has never seen** checks only through `Bundle.members_since`, every revision since the one it holds, each against the one before.

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
- **A touch that lands after another device answered releases nothing.** The lease store approves only a pending lease.

The presenter puts up one panel at a time, as one value: idle, showing an item, or closing an item (the outcome stays 2.5 seconds, a denial 10; the practice request goes at once, since first run's window says what happened). It always shows the first waiting item it can build; one whose request has gone is skipped, never left half-shown.

Found and fixed: the panel used to write "sending" into the request's own state, so an update arriving mid-send had to be skipped by hand, and the presenter kept six fields (`shownItem`, `shownRequest`, `question`, `showing`, `closingAfterAnswer`, `needsFingerprint`); a request that vanished between being chosen and being shown left the presenter pointing at the previous one. Test: `anUpdateWhileHisDenialIsSentDoesNotUndoIt`.

## The Mac's doors

Written by AI on 2026.11.21 by model claude opus 5.5. Code: `AgentKeyringFeature/MacDevice.swift` (`Door`, `reconcileDoor`), `DoorServer.swift`.

The Mac serves two doors on its Tailscale address, with its machine TLS key:

- the answer door, port 17446: POST /v2/answer, /v2/arrived and /v2/end, with no client certificate, so the Apple Watch and a locked iPhone can reach it;
- the members' door, port 17447: joining and the lists. A client certificate is required, and each route checks it is a member's, or for a join the joiner's own.

macOS's TLS can require a client certificate or ask for none, never ask and go on without one, so one port cannot serve both. Every door speaks HTTP/1.1, one request per connection, with Content-Length bodies.

One value, `MacDevice.door`:

| Door | Reached by | Next |
|---|---|---|
| opening | the app starts; the address changed | open, failed, noTailscale |
| noTailscale | this Mac has no address in 100.64.0.0/10 or fd7a:115c:a1e0::/48: Tailscale is not installed, not running, or signed out | opening, when an address appears |
| open(host, answers, members) | both ports bound on that address | opening when the address changes; noTailscale when it goes |
| failed(reason) | a port could not be bound | opening, ten seconds later |

The address is read from the Mac's interfaces whenever the network changes (`NWPathMonitor`), never a name. noTailscale is its own state, with its own sentence (`MessageCopy.noTailscale`): no invitation can be made in it (`inviteMachine` throws that sentence), an agent's request is shown on this Mac only and the log says why (`devicesUnreachable`), and the item in iCloud Keychain names this Mac only.

## Joining the Mac

Written by AI on 2026.11.21 by model claude opus 5.5. Code: `AgentKeyringFeature/MacJoins.swift`. Test: `MacDoorTests`.

Invitations: while the door is open, the item in iCloud Keychain holds a full invitation: this Mac's name and key id, the members' door's address, port and key, a secret, and seven days. One already there is kept while it names the door as it is and has a day left. `agent-keyring invite` makes a ten-minute one for a computer. Each secret admits one joiner: once its join is approved, refused or withdrawn, the secret is retired, and the item gets a new one.

One join per joiner (a computer's machine id, a device's key id), each with one state:

| Join | Reached by | Next |
|---|---|---|
| (none) | POST /v2/join whose proof checks against an open invitation, over the joiner's own TLS key (an Apple Watch: through its added iPhone) | waiting |
| waiting | Touch ID on the panel | approved |
| waiting | Deny | refused |
| waiting | ten minutes after it was first asked, connected or not | expired |
| waiting | POST /v2/join/withdraw from the same key; or a second joiner proves the same invitation, when both go and neither is shown | withdrawn |

Approval publishes the members list (the first one, with this Mac's device and machine, if none), signs the first catalogue if there is none, fills a device's copies, and gives a computer the push credential sealed to its receiving key. A computer approved while the Mac has no push key is approved without it (logged `no-push-key`). Refusal gives a computer's agent his words with their proof.

A join's long poll replies at once if decided, else after 25 seconds still waiting; posting it again goes on waiting and does not move its ten minutes. A joiner already in the members list with exactly these keys is approved at once, so a poll that dropped after his Touch ID still hears it. Joins are not saved: after a restart the joiner asks again.

## The Mac's lists

Written by AI on 2026.11.21 by model claude opus 5.5. Code: `MacDevice.swift`.

Kept in the app's keychain (`MacStorage`): the signed members list and every revision of it, the signed catalogue as last signed here or on the iPhone, the copies revision, and each device's signed push registration (the newest for each device wins; an iPhone registers its Watch's). The push key from `agent-keyring push-key` is in the same keychain. The sealed copies are in `LoginStore`.

- **GET /v2/bundle?members=N** gives the members list, every revision after N, the catalogue, the push registrations, the revisions, and the caller's copies: to a device its own; to a computer the Apple Watches' and its own Automatic ones. Only copies of the signed catalogue's current version are given, never a Blocked one, so copies from an import he has not yet approved sending stay on the Mac.
- **From the iPhone**: a members list, checked against the one held (a device or computer it leaves out keeps no copy or push registration here); a catalogue, when a rule changed there; copies (the Watch's), each checked against its signer and the catalogue's version; practice asks; logs. Computers send complaints, kept in one owner-only file and shown on no screen.
- **A rule changed on the iPhone** arrives as the catalogue only. The Mac takes its rules, withdraws every computer's copies of a password no longer Automatic, and if a computer allowed Automatic passwords lacks a copy of one, the panel asks for Touch ID to make them (`automaticCopiesMissing`, read from the copies after each catalogue and after the copies are made; "Not now" clears it until the next catalogue).
- **The rev push**: whenever the members, the catalogue or any copy changes, the iPhone gets a silent push a second later (collapse id "rev") and fetches its bundle. Nothing depends on it arriving.

## The Mac's own requests

Written by AI on 2026.11.21 by model claude opus 5.5. Code: `AgentKeyringFeature/MacAsks.swift`, `CredentialLeaseStore.swift`. Test: `MacDoorTests`.

When an agent's lease waits, the door is open, the push key is held and an iPhone or Apple Watch is listed, the Mac signs a request naming its answer door and key. The reason is cut to 400 bytes and the agent, project and task to 100, so the push fits Apple's 4 KB. The Mac saves the link from the lease to that request in the lease store and pushes it through Apple to every device with a push registration; the Watch's push carries its copy. The lease store is the record and moves as always; the devices follow it:

| Lease on the Mac | Reached by | Told to the devices as |
|---|---|---|
| pending | the agent asked | the visible push |
| active | Touch ID in the panel; or an approval at the answer door, whose delivery opens with this Mac's receiving key (`approvedBy` the signer's kind: iphone or watch) | approved, by that device or this Mac |
| denied | Deny in the panel; or a denial at the answer door, recorded as the signer's device (a plain denial as the iPhone's); the hold applies | denied |
| unanswered, cancelled | ten minutes; the agent stopped | the same |
| released, expired, revoked | the agent's release; 30 minutes; Stop on a device (POST /v2/end, `ended_by` that device), in the menu bar, or a restart | ended |

Each change is one silent push per device, in order with the request's other pushes. The first answer wins: a later one gets 200 with the request as it stands; an answer from a device not in the members list, or over other bytes, gets 403. Apple's acceptance and the arrival note (signed, or unsigned naming the SHA-256 of the push address the Mac used) are kept as how far it has got. After a restart the Mac reads the saved links: a lease still pending takes its answers again, and one that ended meanwhile is told once. The link goes when the lease ends.

A practice request is the same with no lease. It has its own state (waiting, then approved, denied, or unanswered after ten minutes); only the device it names may answer it; an approval needs no delivery; and its outcome also goes to the device that asked for it.

Known and left alone: requests from agents on other computers no longer reach this Mac, which cannot be pushed to. Those computers push to the iPhone and Apple Watch themselves.


## iPhone: first run

Code: `PhoneFirstRun` in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/PhoneFirstRun.swift`. `PhoneKeyring` sends it events and does what each state asks. Tests: `PhoneFirstRunTests`.

There is no relay. The iPhone joins the Mac at the Mac's members' door (HTTPS on its Tailscale IP, port 17447, pinned to its key, with the iPhone's TLS client certificate), and the Mac's join card in iCloud Keychain says where that door is. Each state is one screen; the pages themselves are built from the shared page parts.

### States

| State | Screen |
|---|---|
| `searching(longWait)` | Looking for the Mac's join card. `longWait`: two minutes with nothing found, so Having Trouble shows. |
| `trouble` | "Check these three things", with Try Again. |
| `foundMac(name)` | "Continue setup from <Mac>", with Connect and Having Trouble. Nothing is asked of the Mac yet. |
| `waitingForMac(name)` | The request to join waits on the Mac, with Cancel. |
| `deniedByMac(name)` | The Mac refused, with Ask Again and Cancel. |
| `cantReachMac(name)` | The Mac's door could not be reached, with Try Again and Cancel. |
| `expired(name)` | Ten minutes with no answer from the Mac, with Ask Again and Cancel. |
| `receivingPasswords` | This iPhone's copies arriving from the Mac, with how many of how many. |
| `notifications` | "Turn on notifications" with the checklist, ticked from what iOS allows: Turn On Notifications until iOS has asked, then Continue, with Open Settings while a box is unticked. |
| `askingNotifications` | iOS's own question, over the same screen. |
| `notificationsOff` | Notifications are off, with Open Settings and Continue Without Notifications. |
| `practiceOffer` | Send Practice Request, Skip for Now. |
| `practiceWaiting(id, arrived)` | Waiting for practice request `id`; `arrived`: it is here and its notification waits for a tap. |
| `settingUpNotifications(id)` | 30 seconds and Apple has given no push address, with Skip for Now. |
| `practiceNotArrived(id)` | 30 seconds and nothing arrived, with Try Again and Skip for Now. |
| `practiceMacUnreachable(id)` | The Mac, which makes practice requests, could not be reached, with Try Again and Skip for Now. |
| `practice(id)` | Practice request `id`, open as a sheet. |
| `practiceResult(outcome)` | Approved, denied or no answer, with Send Another and Continue. It stays until he goes on. |
| `readyOfferWatch(watchToAdd)` | "Add your Apple Watch?" with Add Apple Watch and Done when a Watch is paired and not added; otherwise Done. |
| `addWatch` | The Apple Watch flow (below) runs; when it closes, `finished`. |
| `finished` | The app's tabs, Home first. |

### What must always be true

- First run has one state, saved on every change. Every first-run screen and every step the app takes in it follow from that state alone.
- Nothing asks the Mac before Connect: the join is posted only in `waitingForMac` (`mayJoin`). The look for the card is a local read every three seconds, before Connect and while waiting (`looksForMac`).
- While the answer is WAITING, the same join is posted again: the Mac answers within 25 seconds. Leaving the app cuts the call; `waitingForMac` is saved and the join is posted again on return. A Mac that never answered is `cantReachMac`; one that stops answering after it said WAITING is tried for 30 seconds first.
- Cancel posts `/v2/join/withdraw`; refused and expired come from the Mac's answer. None of the three asks again by itself: only Ask Again or Try Again. Test: `refusalAndExpiryWaitForHim`.
- A practice request has one id, chosen by this iPhone and saved. The Mac makes it (`POST /v2/practice`), and the same id rejoins it; if one is waiting already the Mac answers with that one, and first run takes its id (`practiceSent`). A new id is made only by Send Practice Request, Send Another or Try Again. Test: `practiceKeepsItsID`.
- After a relaunch, any practice state becomes `practiceWaiting(id, false)`; the result stays until he goes on. Test: `resultStays`.
- An event the table does not list for a state leaves the state unchanged.
- Timers stay outside the machine and arrive as events: two minutes for `lookedLong`, 30 seconds for `practiceTimedOut`, and a minute with no new copies ends `receivingPasswords` (the rest come with the next fetch).

### Transitions

| From | Event | To |
|---|---|---|
| any | `removed` (this iPhone left the list of devices) | `searching(false)` |
| `searching`, `trouble` | `macFound(name)` | `foundMac(name)` |
| `searching(false)` | `lookedLong` | `trouble` |
| `searching`, `foundMac` | `havingTrouble` | `trouble` |
| `trouble` | `tryAgain`, `cancel` | `searching(false)` |
| `foundMac` | `macGone` | `searching(false)` |
| `foundMac(name)` | `connect` | `waitingForMac(name)` |
| `waitingForMac`, `deniedByMac`, `cantReachMac`, `expired` | `cancel` | `foundMac(name)` |
| `waitingForMac` | `joinRefused` / `macUnreachable` / `joinExpired` | `deniedByMac` / `cantReachMac` / `expired` |
| `deniedByMac`, `expired` | `askAgain` | `waitingForMac` |
| `cantReachMac` | `tryAgain` | `waitingForMac` |
| `waitingForMac` | `joined` | `receivingPasswords` |
| `receivingPasswords` | `passwordsReceived` | `notifications` |
| `notifications` | `continueTapped` | `askingNotifications` |
| `askingNotifications`, `notificationsOff` | `notificationsAnswered(true)` | `notifications` (the checklist stays) |
| `notifications` | `notificationsDone` (Continue) | `practiceOffer` |
| `notifications`, `askingNotifications` | `notificationsAnswered(false)` | `notificationsOff` |
| `notificationsOff` | `continueWithoutNotifications` | `practiceOffer` |
| `practiceOffer`, `practiceResult`, `practiceNotArrived`, `practiceMacUnreachable` | `sendPractice(id)` | `practiceWaiting(id, false)` |
| practice states | `practiceSent(id)` | the same state with that id |
| `practiceWaiting(id, false)` | `practiceArrived(pushExpected)` | `practiceWaiting(id, true)` if a push is expected, else `practice(id)` |
| `settingUpNotifications`, `practiceNotArrived` | `practiceArrived` | `practice(id)` |
| `practiceWaiting`, `settingUpNotifications`, `practiceNotArrived` | `practiceTapped` | `practice(id)` |
| `practiceWaiting(id, true)` | `practiceTimedOut` | `practice(id)` |
| `practiceWaiting(id, false)` | `practiceTimedOut(pushAddress)` | `practiceNotArrived(id)` if Apple gave an address, else `settingUpNotifications(id)` |
| `practiceWaiting(id, false)`, `settingUpNotifications` | `practiceMacUnreachable` | `practiceMacUnreachable(id)` |
| practice states and `practice` | `practiceEnded(outcome)` | `practiceResult(outcome)` |
| `practiceOffer`, `practiceResult`, `practiceNotArrived`, `settingUpNotifications`, `practiceMacUnreachable` | `continueAfterPractice(watchToAdd)` | `readyOfferWatch(watchToAdd)` |
| `readyOfferWatch(true)` | `addAppleWatch` | `addWatch` |
| `readyOfferWatch`, `addWatch` | `done` | `finished` |

## iPhone: adding Apple Watch

Code: `PhoneAddWatch` in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/PhoneAddWatch.swift`; `PhoneKeyring` holds the Face ID confirmation and does the work. Tests: `PhoneAddWatchTests`. The same flow opens from the end of first run and from Add Apple Watch in Devices.

| State | Screen |
|---|---|
| `notPaired` | No Apple Watch is paired with this iPhone, with Close. |
| `watchAppMissing` | Install Agent Keyring on Apple Watch, in words (no app can open Apple's Watch app at Available Apps), with Check Again; it also moves on by itself when WatchConnectivity says it is installed. |
| `faceIDFirst` | Why adding it needs Face ID, with Continue with Face ID and Cancel. |
| `waitingForWatch(until)` | "Confirmed with Face ID · ready until 14:17", "Now tap Add on your Apple Watch", with Cancel. |
| `faceIDExpired` | The confirmation ended, or iOS closed the app: Continue with Face ID again, with its reason. |
| `watchNeedsPasscode(until)` | Apple Watch has no passcode (from its self-test), with Try Again. |
| `encrypting(done, total)` | This iPhone encrypts a copy of each password for Apple Watch. |
| `copiesFailed(reason)` | Apple Watch is listed but its copies did not reach the Mac, with Try Again (copies only) and Cancel. |
| `added` | Apple Watch added, with Done. |
| `closed` | The flow is over. |

What must always be true:
- Face ID comes first, after the page says why. Nothing is decrypted until Apple Watch asks: the authenticated LAContext is held, with its end shown (`PhoneAddWatch.hold`, ten minutes), and used for the key operations then. Face ID is asked again, with its reason, only if the end passes or iOS closed the app; never twice in a row otherwise. Test: `confirmationIsHeldThenLapses`.
- Apple Watch offers Add only while the iPhone waits: the iPhone sends the confirmation's end to the Watch (`addUntil`) and withdraws it when the wait ends.
- If Apple Watch asked before Face ID (its keys arrived first), adding goes on as soon as the confirmation is given.
- Adding lists Apple Watch (`POST /v2/members`), then sends its copies (`POST /v2/copies`). If the copies fail, the Watch stays listed and Try Again sends only the copies, with the held confirmation or a new one. Test: `copiesFailedIsExplicit`.

## iPhone: every day

Code: `PhoneHomeView`, `PhoneLoginsView`, `PhoneDevicesView` and `PhoneSettingsView` in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/PhoneTabs.swift`. These screens hold no state of their own: each shows the snapshot, and each button sends one call.

- The iPhone learns of a request only from its push: the notice in it carries the request. The app reads the notice when the notification arrives with the app in front, when it is opened, and, on coming to the front, from every notification still in Notification Centre. Nothing depends on dialling the iPhone.
- It keeps its own copy of every password that is not Blocked, from the Mac's bundle (`GET /v2/bundle`), fetched on coming to the front and when the Mac's silent push says something changed. Approve opens its own copy after Face ID, checked against the signed Catalogue; if it has none, it fetches once, and if the Mac cannot be reached it says the password is not on this iPhone yet.
- Answers, arrival notes and Stop go to the asking computer's door, named in the signed request, a Tailscale IP pinned to that computer's key in Members (`Sealing.checkRequest`, `Sealing.answerDoor`). An answer that cannot connect is retried for 30 seconds (`AnswerDoor.retryFor`) and shown as not delivered yet meanwhile (`PhoneSnapshot.undelivered`). The door's reply is the request's Lease: this answer's, or the one that ended it first, which is then what is shown.
- Home: Ready, or the one line that says what is wrong (the Mac cannot be reached, so lists and practice wait; still connecting). Devices: Practice on Apple Watch's row asks the Mac for its practice request; Add Apple Watch while a Watch is paired and not added; Remove on every row except this iPhone and a Mac's computer row.

### Facts that are not first run's state

- `pushRegistered`: the Mac has this launch's push address (signed with the reply key).
- `pushSeen`: a push has reached this iPhone. It is saved.
- `facts` (`PhoneNotificationFacts`): what iOS allows (notifications, banners, Lock Screen, Time Sensitive, in the Scheduled Summary), read each time the app comes to the front and after iOS's question.
- Apple Watch's facts (`PhoneWatchFacts`): paired and app installed (WatchConnectivity), opened, added (listed), notifications, push address and practice answered (its self-test).
- `practiceOutcome`: once approved it stays approved (test: `practiceApprovalLatches`).
- `macUnreachable`: the last fetch from the Mac's door failed.

### Reachable faults closed

1. **The join asked twice**, 0.03 seconds after opening and again after leaving the app. Now nothing asks before Connect, and a cut call is "still waiting". Test: `joinIsHisAndSurvivesLeaving`.
2. **Two or three practice requests, and "Your answer wasn't sent".** Now the request keeps its id and is rejoined. Test: `practiceKeepsItsID`.
3. **A refused or expired join asked again by itself**, every few seconds. Now each waits for Ask Again. Test: `refusalAndExpiryWaitForHim`.

## Apple Watch: setup

Code: `WatchSetup` in `AgentKeyringPackage/Sources/AgentKeyringWatchCore/WatchSetup.swift`. `WatchLink.refreshSetup` works it out and `WatchHome` shows it. Test: `WatchSetupTests`.

It is worked out each time from what the Watch reads and the few things it keeps: its passcode; whether the iPhone has sent a signed list; whether that list names this Watch; the end of the iPhone's held confirmation (`addUntil`, from the iPhone's latest context only, never from older queued messages); whether he tapped Add; what watchOS allows; Apple's push address; when Try Practice asked; and whether the practice offer is done.

| State | When | Screen |
|---|---|---|
| `noPasscode` | no passcode | "Set a passcode" |
| `setUpIPhone` | no list from the iPhone | Set up Agent Keyring on your iPhone first |
| `startOnIPhone` | not listed, and the iPhone is not waiting | "Start on your iPhone": Devices, Add Apple Watch |
| `readyToAdd` | not listed, the iPhone waits | "Add this Apple Watch?" with Add |
| `preparing` | not listed, Add tapped | the iPhone is finishing |
| `notifications` | listed, watchOS has not asked | Continue raises watchOS's question |
| `notificationsOff` | notifications denied | "Notifications are off" |
| `settingUpNotifications` | no push address from Apple | "Setting up notifications" |
| `addedOfferPractice` | all in place, practice offer not done | "Apple Watch added", Try Practice and Done |
| `practiceWaiting` | Try Practice asked less than a minute ago | "Practice request sent" |
| `ready` | practice answered, or Done | "Ready", or "In use" while an approval lasts |

What must always be true:
- The Watch sends its keys to the iPhone only after Add, until it is listed. It never asks to be added by itself.
- watchOS asks about notifications only after the iPhone has added this Watch.
- Try Practice asks the iPhone, which asks the Mac (only an iPhone or the Mac can); a practice that has not come within a minute is offered again. Its card has Deny, Approve and Deny and Explain, like any request.
- The Watch keeps no passwords: each request's push carries the one encrypted copy it needs, which only this Watch's Secure Enclave opens.

## Apple Watch: a request's card

Code: `RequestModel.Card` in `AgentKeyringWatch/RequestView.swift`; the answer in `WatchDelegate.answer` in `AgentKeyringWatch/WatchApp.swift`.

| State | Card |
|---|---|
| `opening` | nothing yet |
| `unreadable` | "Open Agent Keyring on your iPhone to see this request." The Watch has asked its iPhone for the list of devices. |
| `showing(request)` | who asks, the site and the account, each on one line, then Deny and Approve, all on the first screen; then the agent's whole reason, once, read by scrolling; then Deny and Explain. An ended request shows its outcome in place of Deny and Approve. |
| `sending(request)` | the same, with the three buttons disabled |
| `answered(request, line)` | "Approved", "Denied", "Already answered" (another device's answer ended it first), or "Not approved. Try on your iPhone."; the card closes 1.2 seconds later |

The three buttons are ours, one kind: Deny (red), Approve (green), Deny and Explain (grey), which opens watchOS's own text entry (dictation, Scribble or keyboard) inside the card. The notification category has no actions of Apple's, so Double Tap has nothing to choose and never answers.

The log has a line when the card is shown (`card shown`, with the request, and how many seconds it waited for the list of devices if it had to) and when it cannot read the request (`card unreadable`, with the error). With the extension's `push named` and `arrival sent`, that times each request from the push to his wrist.

What must always be true:
- An answer goes only to the request on screen, and only once: `respond` works only from `showing`.
- The retry that reads the request again while the list arrives is cancelled when another notification takes the card, and when the card closes.

## Notifications on the iPhone and Apple Watch

- A request's notification goes when it is answered on this device, and when this device learns it has ended (the door's reply, or the asking computer's silent push for every outcome), and never comes back as a separate "Approved on your iPhone" notification. The silent push carries the request id at the top level (`"id"`) and no alert.
- Answering is the same whichever way it comes: the notification's Approve and the app's button can both run for one request; once this iPhone has answered it, or it has ended, a second answer returns without error. Test: `answeringTwice`.
- Tapping a notification opens its request: the notice in the notification carries it.
- On the Watch, the asking computer's silent push for an outcome (`apns-push-type: background`, priority 5, `content-available`, the request id as `"id"`) reaches `didReceiveRemoteNotification`, which removes the request's notification. The Watch app declares `UIBackgroundModes` with `remote-notification`; before bdd2231 it declared `WKBackgroundModes`, which App Store Connect refused, and that is the likely reason answered requests stayed on the Watch. Not yet seen on a real Watch. Apple rations background pushes, so one may still come late; the request's own notification is also removed when its card is answered.

## Deny and Explain on the iPhone

- From a notification, Deny and Explain is a foreground action: it opens the app on that request, with the reply box focused and our microphone beside it. Approve and plain Deny stay on the notification. The Watch keeps its own three buttons.
- The reply box grows with what he says or types, up to ten lines, then scrolls.

### The microphone

Code: `PhoneDictation` and `PhoneSpeechModel` in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/PhoneDictation.swift`. Apple's on-device transcription (SpeechAnalyzer with SpeechTranscriber).

The language's speech model (`PhoneSpeechModel`): `unknown`, `downloading(percent)`, `ready(locale)`, `unsupported(language)`, `failed`. It is fetched when the iPhone joins, so the first tap works, and again before listening if it is missing.

| State | Under the reply box |
|---|---|
| `idle` | nothing |
| `starting` | nothing; the button shows it is listening |
| `listening(settled, tentative)` | the words, written into the box as they are heard |
| `cannotListen(microphoneOff)` | one line, with Open Settings |
| `cannotListen(gettingReady(percent))` | one line: the speech model is still downloading |
| `cannotListen(unsupported(language))` | one line naming the language |
| `cannotListen(failed)` | one line |

It never moves to the keyboard without a word. Every step is logged: tapped, listening, stopped, cannot listen with the reason, and the model's downloading, ready, unsupported and download failed.
