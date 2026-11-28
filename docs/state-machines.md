---
written_by: ai (Claude Opus 5.5, 2026-11-19; the doors cut on 2026-11-24 by the same model). The Mac and command sections are the core engineer's; the iPhone and Apple Watch engineer adds theirs.
---

# State machines

These are the places where Agent Keyring remembers where something is up to: their states, what must always be true, and what moves them. Each section names the code it describes. When the code changes, change the section with it.

What this file does not claim: that no other state exists. The sections below are the ones checked line by line against the code on 19 and 20 November 2026. Each ends with what was found that can actually go wrong, and what was done about it.

## This Mac's keys (before first run)

Written by AI on 2026.11.23 by model claude opus 5.5. Code: `AgentKeyringEngine/Mac/MacHardwareSetupFlow.swift` (states and transitions, pure), `MacKeyringEngine.prepareKeys`, `sendSetup` and `usePasswordOnThisMac`, `AgentKeyringApprovalCore/MacApprovalMode.swift` (the mode, `MacProbe` and `MacHardware`), `AgentKeyringApprovalUI/Mac/MacSetupPages.swift` `ThisMacPage` (draws it). Tests: `ThisMacSetupTests`.

One value, `MacHardwareSetupFlow`, held by the model and never saved: until keys exist, every launch starts again from the facts. Where it starts (`MacHardwareSetupFlow.initialFlow`):

| Keys saved | Hardware (`MacProbe.hardware`) | Start |
|---|---|---|
| yes | any | ready: the saved keys and their mode are used as they are |
| no | touchID (also lid shut, keyboard disconnected, no fingerprint) | ready: Touch ID keys are made at launch if Touch ID works now; otherwise step 1 says why, and they are made on first use |
| no | noTouchID (`biometryNotPaired` or `biometryNotAvailable`, lid open) | askHowUsed |
| no | noSecureEnclave | noSecureEnclave |

| State | Event | Next |
|---|---|---|
| loading | launch looked (keys saved, hardware) | the start above |
| askHowUsed | A Mac for agents | forAgents: the command's install and how to add this Mac; Quit |
| askHowUsed | My personal Mac | personalMac: the trade-off; Use My Mac Password |
| forAgents, personalMac | Back | askHowUsed |
| personalMac | keys made (`MacApprovalMode.devicePassword`) | ready: first run's Welcome |
| personalMac | keys failed | personalMac, with the reason |
| loading, ready | keys failed | keysFailed, with the reason |
| keysFailed | Try Again | loading, then looks again |
| loading, ready, keysFailed | keys made | ready |

What must always be true:

- **Saved keys never change.** `MacKeys.make` does everything that can fail (the TLS identity, the Secure Enclave keys, reading them back) before it saves. The TLS identity (service `….keys.v2.tls`) may already exist from an earlier attempt or install; `DeviceTLSIdentity.loadOrCreate` reuses it, so a retry is safe. It then saves with an add that never overwrites (`DeviceKeychainStore.add`); if keys are already saved it throws `alreadyMade` and the caller loads them, so two launches end up with the same keys and a failure leaves nothing behind. Their mode is saved with them; a vault saved before modes existed is Touch ID or the Watch. A Mac whose Touch ID keyboard is gone keeps its Touch ID keys and is never asked how it is used: it says to reconnect Touch ID or answer on the iPhone or Apple Watch.
- **Only Use My Mac Password makes Mac password keys.** Lazy `macKeys()` calls load saved keys, or make Touch ID keys on a Mac with Touch ID, and never make keys while setup is asking.
- **A failure is shown, never swallowed.** Keys that can't be read or made put the reason on screen with Try Again. Launch looks only while loading, so a failure stays on screen until Try Again. Mac password keys are made only after macOS confirms the Mac has a login password.
- **Every change goes through `MacHardwareSetupFlow.after`**, logged by `sendSetup`; keys adopted from anywhere send `keysMade`.
- **The invitation in iCloud Keychain belongs to the device that left it.** A new install removes it only if its `inviter_key_id` is this Mac's own key, so opening the app on a Mac for agents never removes the personal Mac's invitation. A running Mac never replaces another device's invitation either (`MacSyncCoordinator.leaveInvitation`); only opening "Add your iPhone" on a Mac makes it that Mac's (`leaveInvitationForIPhone`). An iPhone that holds the lists replaces only one left by a device outside its list (`PhoneKeyringEngine.leaveInvitation`).
- **The window shows setup first.** While `MacHardwareSetupFlow.isAsking`, the window is `ThisMacPage`, whatever first run says, and it opens at launch.

## Mac first run

Rewritten by AI on 2026.11.21 by model claude opus 5.5, for the four local steps. Code: `AgentKeyringEngine/Mac/MacFirstRunFlow.swift` (states and transitions, pure), `MacKeyringEngine.sendFirstRunEvent` (saves each move), `AgentKeyring/AgentKeyringApp.swift` `FirstRunHome` and `AgentKeyringScreenBackends/SetupScreens.swift` (map the state and the facts to the pages), `AgentKeyringApprovalUI/Mac/MacSetupPages.swift` (draw them). Tests: `FirstRunTests`.

One value, `MacFirstRunFlow`, is saved in the app's settings: the window he is on (`step`) and the practice request on step 1 (`practice`), kept when he moves on so Back finds his answer. First run asks nothing of any other device. Facts the world owns are read beside it and never copied into it:

- Touch ID, the Watch or the Mac password can be used: `MacApprover.shared.state` (ready, lid closed, no fingerprint, Touch ID keyboard missing). A Mac in Mac password mode is always ready.
- His passwords: copied (the list holds more than the test password) or the test password only.
- How far a copy from Passwords has got: `MacKeyringEngine.passwordsCopy` (below).
- Which devices and computers have joined: the members list, read each time Ready is drawn.

| Step | Practice | Event | Next |
|---|---|---|---|
| welcome | | Get Started | practice |
| practice | notSent, approved, denied | Send Practice Request (a new id) | practice, waiting(id): the card appears beside the window |
| practice | waiting(id) | approved for id / denied for id, with his words | practice, approved / denied(reply) |
| practice | approved, denied | Continue | copy |
| practice | any | Back | welcome, with practice notSent |
| copy | | Back | practice, answer kept |
| copy | | Continue (shown only once his passwords are copied) / Use Test Password Only | connectAgent(notTried) |
| connectAgent(notTried) | | the first request from an agent on this Mac is approved or denied, on any device | connectAgent(worked(agent) / denied(agent)) |
| connectAgent(notTried) | | Skip the Test | ready |
| connectAgent(worked, denied) | | Continue | ready |
| connectAgent | | Back | copy |
| ready | | Show Passwords | finished: the same window becomes Passwords and Devices |

An event with no row leaves the state as it is. The device sheets opened from Ready (below) change nothing here; closing one leaves him on Ready.

What must always be true:

- **Exactly one window.** The window is `MacFirstRunFlow` and the facts above; nothing else chooses it.
- **The practice card appears only after Send Practice Request**, and answers only the request it was opened for: the card's backend takes the id when he clicks, so a Touch ID that lands late cannot answer a newer request. When the lid is closed or Touch ID has no fingerprint, step 1 says so and Send Practice Request is off.
- **Connect an agent has no waiting line.** The app cannot know that he pasted the note anywhere. The page says what to expect, and then shows the outcome of the first real request.
- **Only Show Passwords finishes first run.** Quitting on Ready opens on Ready.
- **A restart never strands him.** Every state resumes as saved, except that a practice request left waiting becomes notSent, so nothing appears beside the window by itself. An earlier build saved first run as one enum: its finished opens as finished, and anything else (its journey of chosen devices) starts first run again at Welcome. A Mac that finished first run before it was saved at all opens as finished.
- **The request card never covers the window that explains it.** It goes to the right of Agent Keyring's window, else to its left, else the window moves to the screen's left edge (`RequestPanel.frame`).
- **A fresh container is a new install.** On its first launch the app deletes what an earlier install left in the keychain and keeps this Mac's keys (`MacKeyringEngine.forgetPreviousInstall`).
- **There is always exactly one test password**, and a copy from Passwords replaces the list one entry for one entry (`VaultSnapshotMerger`), keeping each entry's id and so its rule.

Deleted with the journey on 21 November: the device choice (`Devices`, `chooseDevices`), the pages built from it (`pages(for:)`), `Facts`, `.deviceDone`, `firstRunFacts`, the page for a computer that stays on, `JourneyStepKind`, and `SelfTestReport.journey`, `step` and `finished` with the `JourneyStep` enum in the protocol (numbers 5 to 7 reserved).

### Adding an iPhone or a computer

Code: `MacAddIPhoneSheet` and `MacAddComputerSheet` in `AgentKeyringApprovalUI/Mac/MacDeviceSheets.swift`, worked out by `SetupScreens.addIPhone` and `addComputer` from `MacSyncCoordinator.cloudState`, `filling`, the members list and `joinHistory`. The same sheets open from Ready and from Devices. Each holds only what it was opened with: the iPhone sheet, when it opened and which iPhones were already listed; the computer sheet, the invitation it made.

Add your iPhone, in order of what wins:

| State | When |
|---|---|
| problem | this Mac has no keys yet |
| noICloud | this Mac is signed out of iCloud, or iCloud failed: the iPhone joins through iCloud, so it cannot find this Mac. Check Again reads iCloud now. |
| copying(name, done, total) | an iPhone (not an Apple Watch) not listed when the sheet opened is being given its copies |
| stopped(name, done, total, reason) | its copies stopped; `filling` keeps the reason for 30 seconds, then the iPhone shows as added. Adding the rest needs it removed and added again. |
| added(name) | an iPhone not listed when the sheet opened is in the members list |
| joinAsked(name) | an iPhone's join is waiting: the card is beside the window |
| waiting(notAdded) | otherwise; `notAdded` names an iPhone refused, withdrawn or run out since the sheet opened |

Add another computer: starting while its code is not made yet; otherwise the sheet's code (`MacSyncCoordinator.machineInvite`, ten minutes, one joiner, through boxes at the relay) decides: withdrawn if its join was withdrawn; then the join it admitted, as joinAsked, added, notAdded (refused) or expired; with no join, expired once its time passes (the sheet is drawn again at that moment) and otherwise the code with its time. Create New Invite makes a new code.

### Adding a device, after Touch ID

`MacSyncCoordinator.approveJoin`: after his Touch ID the device is in the members list at once. A new iPhone or Apple Watch also signs the catalogue again, so the list it is filled from is the one the devices are told about, changes from a copy included. It then needs a copy of every password: this Mac opens its own copies with the same approval and seals them again for the device in batches of 50, off the main thread (`TouchIDCopyResealer`); `MacSyncCoordinator.filling` (the device, how many done, of how many) is set while that runs, and the card beside the window says "Copying your passwords to it: n of 547." If the app quits mid-way, the device has the batches already saved; adding the rest needs his Touch ID again (known and left alone). Joining itself is "Joining the Mac", below.

### Practice requests from the Mac

Send Practice Request on another device, in Devices, makes a practice request for that device and pushes it (`MacSyncCoordinator.sendPracticeRequest(on:)`; "The Mac's own requests", below), answered in its answer box. The row shows each step: sending, with Apple (Apple accepted the push), then the answer. While one waits for a device, a second is never made. Another device's practice request for this Mac arrives as a push and shows the practice card here; its answer goes in that request's box.

### The test password

`StoredVaultLogin.testPassword`: example.com, you@example.com, password "hello". The first copy brings it (`MacKeyringEngine.importBatch`) and every later copy keeps it, as it keeps any password missing from an export; "Use Test Password Only" is a copy of nothing. It is an ordinary Ask password: in his list and the catalogue like any other, so an agent on any of his computers can try the whole route with a secret that does not matter.

### Copying from the Passwords app

Code: `PasswordsCopy` in `MacFirstRunFlow.swift`, `MacCredentialExchangeImport.swift`. First run's "Copy your passwords" and the main window's Copy Again are the same page (`MacCopyPage`) and the same value, `MacKeyringEngine.passwordsCopy`. It is nil when no copy is open; first run draws nil as the guide, and the main window shows its list. It is not saved. Beside it, `copyGuideStep` (1 to 5) is which step of the guide he is reading; only Previous and Next move it.

| State | Event | Next |
|---|---|---|
| nil or steps | Open Passwords (Copy Again in the main window) | waiting |
| waiting | five minutes with nothing | noneArrived |
| steps, waiting or noneArrived | "Agent Keyring isn't in the list?" | allowExport: the AutoFill sheet |
| allowExport | Open AutoFill Settings | allowExport: System Settings opens at AutoFill |
| allowExport | the app comes to the front and Agent Keyring is on in AutoFill | steps: he starts the export again |
| allowExport | Cancel | steps |
| any | the export starts arriving | copying |
| copying | sealed and saved | nil; first run shows "n passwords copied" and Continue |
| copying | failed | steps, with the reason under the guide |
| any | Use Test Password Only, or Cancel in the main window | nil |

Found and fixed (tests in `FirstRunTests`):

- **A second copy from Passwords doubled the list** (20 Nov): the next copy goes back to one of each, keeping the entries his rules are on (`SnapshotMergerTests`).
- **A late timer.** The five-minute timer moves the copy on only from `waiting`, so it cannot fire after the passwords arrived.
- **Adding his iPhone froze the Mac for about two minutes** (20 Nov): the iPhone is now added first and its copies follow off the main thread, with progress.
- **A practice approval moved first run by itself** from inside the Touch ID check; a late touch could answer a newer request. Now the card's backend sends the answer for the id it was opened with (`lateAnswer`).
- **"Not Now" took the iPhone's copies away** (found 21 Nov, reading the code). A copy from Passwords deleted the other devices' copies of every password it brought, while the signed catalogue still named their old versions, and the iPhone replaces its copies with what its bundle holds. Now the other devices' copies of the versions the signed catalogue names are kept until the catalogue is signed again, and pruned then (`MacSyncCoordinator.publish`). This Mac's own copies, and its own Automatic ones, are always the newest (`MacBoxTests.aComputerKeepsItsCopiesUntilTheChangesAreSent`).

### Sending changes to the other devices

Code: `MacUnsentChangesPublisher.swift` (`publishChanges`), `MacCredentialExchangeImport.swift`, `MacDevicesTab` (the banner), `MacPasswordsTab` (the footer). Updated by AI (Claude Opus 5.5) on 2026-11-24: the "Send n changes?" panel and Not Now are gone.

`MacKeyringEngine.sentList` is the list the other devices last received, by password id and last-changed date, saved in the app's settings. It is written each time the catalogue is signed (`MacSyncCoordinator.onPublished`): a device joining, a rule change, or a copy sent. A Mac whose devices joined before it was kept starts from the signed catalogue's ids, with no dates. What is unsent is always the current list against it (`unsentChanges`: added, changed by last-changed date, removed), so it survives a quit; it is nothing while no other device or computer holds the list.

| State | Event | Next |
|---|---|---|
| nothing unsent | a copy from Passwords finishes and changed something | sending: macOS's own Touch ID (or Mac password) dialog, "send your password changes to your other devices"; never inside the catalogue's serializer |
| nothing unsent | a copy from Passwords finishes and changed nothing | nothing unsent; the Passwords footer says "Copied on (date): no password changes." until the next copy |
| sending | Touch ID | nothing unsent: the catalogue is signed and sent, and computers' mailboxes are written |
| sending | cancelled, or sending failed | unsent: the Devices banner, with Send Updates… |
| unsent | Send Updates… | sending |
| unsent | another device signed the same revision and its rules were merged in (`onCatalogueConflict`) | unsent: the banner, until Send Updates… |

The Copy Again page says, before the copy, that one Touch ID then updates the other devices (`FirstRunCopy.copyAgainBody`), only while other devices hold the list. A Mac that joined another device's list skips copying in first run once the catalogue is here and the passwords it lists have arrived, an empty list included (`MacCopyPage.State.synced`).

## A request from a computer without the app

Written by AI on 2026.11.21 by model claude opus 5.5; through answer boxes only, with the doors cut, on 2026.11.24. Code: `internal/remote/remote_lease_exchange.go` (asking, settling, release, opening), `internal/remote/remote_answer_polling.go` (taking an answer from its box), `internal/remote/remote_push_dispatch.go`, `cmd/agent-keyring/main.go` `leaseState` (the word `status` prints). Tests: `e2e/remote_test.go`.

The computer an agent asks from owns its request. The record is one `agentkeyring.v2.Lease` for each request (`ExpectedRequest.lease` in the command's state file, `internal/clientstate/state.proto`), changed only under the state file's lock, by whichever of the computer's command processes sees the event. Every request names a new answer box at the relay the computer enrolled through (`answer_box_id`, `answer_box_key`, and `answer_box_url` when not `push.opentrawl.sh`).

| State | Reached by | Who moves it on | `status` |
|---|---|---|---|
| WAITING | `lease`: the request is signed with this computer's key, saved, then pushed to each device with a push address, the Mac's included | an answer picked up from its box; `release`; `answer_by` passing | pending |
| APPROVED | a device's signed approval (the Mac's too: it answers like any device) that checks against the newest Members held and opens with this computer's receiving key; or, Automatic, at once: the catalogue says Automatic, Members allows this computer, its Freshness has not run out, and its own copy checks | `release`; Stop on any device, found at the grant before a use (below); 30 minutes | active |
| DENIED | a signed denial (his words kept only as signed), or a plain denial naming the request id | nothing | denied |
| UNANSWERED | `answer_by` passed while it waited; or the answer in its box did not open or was refused | nothing | unanswered |
| CANCELLED | `release` while it waited | nothing | cancelled |
| ENDED | `release`; Stop (`ended_by` set); 30 minutes | nothing | released, stopped by Josh, or expired |

While it waits, `pushed_unix_seconds` is set when Apple first takes a visible push.

What must always be true:

- **Whoever moves a request on tells the devices, once.** The process that takes an answer from its box or finds a Stop at the grant; the process that notices `answer_by` or the 30 minutes pass; `release` for the agent. Each sends the silent outcome push to every device, the Mac's included. Every command settles any request whose time has passed before it does anything else (`settleDue`), so the devices hear how it ended even after the agent that asked has gone. An Automatic use gets a silent push when it starts, so the devices can show it in use and stop it.
- **The first answer wins.** Answers are taken under the state file's lock. A box holds one answer: a second device's put is refused (409), and its answer is told the outcome by push.
- **An answer is judged by when Josh gave it.** A box is read only while a command here runs, so a signed answer counts if the device says it was decided before `answer_by`, and is still picked up a little after.
- **A device Josh removed cannot answer.** Before checking an answer, the command reads its update mailbox, for 1.5 seconds at most, then checks against the newest Members it holds. An answer that does not check ends the request unanswered, logged `answer refused ... route=box`.
- **One task, one request.** The same request id, or the same task asking for the same password while its request waits or its approval lasts, rejoins that request; nothing is pushed again.
- **A denial holds the password off for this computer.** A minute after the first denial, five after a second in a row, fifteen after more; an approval, or an hour with no denial, starts again at a minute. The agent is told the time it may ask again and his reply word for word (`State.holds`). For an agent on the Mac, the Mac's lease store holds it off ("The Mac's own requests", below).
- **Only a request that newly waits is a notification Josh sees and hears.** Every outcome (answered, stopped, released, cancelled, no answer) is a silent push with the request's `id`, so the iPhone and Apple Watch take the notification away.
- **The Mac need not be awake.** Nothing here waits for the Mac: the request goes to the devices through Apple, the answer comes back through its box, and the lists come from the update mailbox.

## A computer's grants and its update mailbox

Code: `internal/remote/remote_grant_stops.go` (`putGrant`, `checkStopInBox`), `internal/remote/remote_update_mailbox.go`, `internal/remote/remote_keyring_client.go` (`keepBundle`, `removed`), `internal/remote/remote_lease_exchange.go` (`fresh`); the Mac's and iPhone's side in `ComputerMailboxPublisher.swift` and `RelayBoxClient.swift`. Test: `e2e/box_test.go`. Written by AI (Claude Opus 5.5) on 2026-11-24; keyring.proto, "Grants and Stop" and "Update mailboxes", is the contract.

An approval has a grant at the relay, for 45 minutes:

| State | Event | Next |
|---|---|---|
| no grant | the answer is taken; an Automatic use starts; or a use finds none put yet | live: created, read token and write token derived from the answer box key |
| live | a use (read, fill, a one-time code): the relay says not stopped and it opens to this request | live: the use goes ahead |
| live | Stop on any device or the Mac (create, then mode "stop" with its signed EndRequest) | stopped, for good |
| stopped | a use: the EndRequest is signed by a device in this computer's Members | ENDED with `ended_by`, saved: every later use is refused, after a restart too |
| any | a use, and the relay cannot be reached, has no grant, or the grant does not open | that use is refused; the approval stays as it is |

The update mailbox, for each Mac and iPhone in Members, one slot each:

| State | Event | Next |
|---|---|---|
| fresh until T | `find`, `lease` or a use: a slot holds a bundle that checks | its lists taken (a catalogue of the same revision with other contents is refused), its copies merged in, T moved to its Freshness if later; then the slot is deleted with the etag read |
| fresh until T | nothing in the slots, or the relay out of reach for 1.5 seconds | unchanged: what it holds is used, and T never moves |
| fresh until T | now is past T | stale: Automatic passwords are asked for instead, and an approval's Freshness makes it fresh again |
| any | a Members that leaves this computer out | removed: every copy, catalogue and approval goes, and every command says it was removed |

Known and left alone:

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

Since 21 November the card is the page parts' `KeyringApprovalCard` (`MacApprovalPanelView`, written by AI with claude opus 5.5): an agent's request, the practice request, a request from another computer, an iPhone or Apple Watch asking to join (Deny as red words under the green button, with no reply box), a computer asking to join (with "Optional note if you deny" beside a red Deny). The green button takes the card's full width and reads "Click to approve with Touch ID" (or Apple Watch, or "your Mac password" on a Mac in Mac password mode); while macOS's dialog is up it reads "Use Touch ID to approve" (or the Watch or password words) and is off. With the lid shut and no Touch ID keyboard working, or with the Touch ID keyboard of a Touch ID vault unplugged and no Watch, it is off and says where the request can still be answered, with the reason under the card. In Mac password mode, moving focus or clicking elsewhere never closes macOS's dialog, since Josh clicks into it to type.

The presenter puts up one panel at a time, as one value: idle, showing an item, or closing an item (the outcome stays 2.5 seconds, a denial 10; the practice request goes at once, since first run's window says what happened). The practice item is shown only while first run's practice waits (`MacFirstRunFlow.waitingPractice`) or Devices sent one to this Mac. It always shows the first waiting item it can build; one whose request has gone is skipped, never left half-shown.

Found and fixed: the panel used to write "sending" into the request's own state, so an update arriving mid-send had to be skipped by hand, and the presenter kept six fields (`shownItem`, `shownRequest`, `question`, `showing`, `closingAfterAnswer`, `needsFingerprint`); a request that vanished between being chosen and being shown left the presenter pointing at the previous one. Test: `anUpdateWhileHisDenialIsSentDoesNotUndoIt`.

## Joining the Mac

Written by AI on 2026.11.21 by model claude opus 5.5; the door's joins cut on 2026.11.24. Code: `AgentKeyringEngine/Mac/MacJoins.swift`, `MacCloud.swift`. Test: `MacBoxTests.aComputerJoinsWithACodeAndGetsItsAutomaticPasswordsAtOnce`.

Invitations: the item in iCloud Keychain holds an invitation for a new iPhone or Mac: this Mac's name and key id, a secret and seven days. One already there is kept while it is this Mac's and has a day left; one an earlier version left naming this Mac's door is replaced. `agent-keyring invite` and Add Another Computer make a ten-minute code for one computer. Each secret admits one joiner: once its join is approved, refused or withdrawn, the secret is retired, and the item gets a new one.

One join per joiner (a computer's machine id, a device's key id), each with one state:

| Join | Reached by | Next |
|---|---|---|
| (none) | a computer's JoinRequest in a code's request box, proving that code; or an iPhone's or Mac's in iCloud, proving the invitation | waiting |
| waiting | Touch ID on the panel | approved |
| waiting | Deny | refused |
| waiting | ten minutes after it was first asked | expired |
| waiting | the joiner takes its request out of iCloud | withdrawn |

Approval publishes the members list (the first one, with this Mac's device and machine, if none), signs the first catalogue if there is none, fills a device's copies, and gives a computer the push credential sealed to its receiving key. A computer approved while the Mac has no push key is approved without it (logged `no-push-key`). Refusal gives a computer's agent his words with their proof.

**With a code** (`ComputerJoinCoordinator`, shared by the Mac and the iPhone): the inviting device picks the computer's JoinRequest up from the code's request box every two seconds until the code runs out, is used or withdrawn, shows it, and puts the JoinStatus in the response box: on approval with the computer's lists, its own Automatic copies, a Freshness and its update mailbox. A join naming a computer already in the members list with other keys is refused, so nobody can take an added computer's place. The iPhone does the same with no Mac (`PhoneVault.swift`, Add Another Computer).

**Through iCloud** (1.1, `MacCloud.swift`): an iPhone writes its JoinRequest as record `join-<its key id>`. It must prove an open invitation, and name an iPhone whose key id is its signing key's. Approval publishes Members to iCloud, and the iPhone, polling the `members` record every three seconds, joins once a revision names it signed by the inviting Mac. The Mac deletes the record once the iPhone is listed, refused or run out; the iPhone reads a missing record, with no list naming it, as refused.

**Joining a list that started on an iPhone** (1.1, `MacJoinsIPhone.swift`, `PhoneJoins.swift`): the mirror of the above. While an iPhone holds the lists it keeps its own invitation in iCloud Keychain. It never replaces one left by a device in its list, so a list that started on a Mac keeps the Mac's; it replaces one left by any other device, such as a new Mac. A Mac with no list whose Welcome finds an iPhone's invitation, and in iCloud a list in which that invitation's device is an iPhone, offers Connect. Connect writes two JoinRequests, each proving the invitation: `join-<machine id>` for the computer its agents run on, then `join-<device key id>` for the approving device, with the same machine key. The iPhone shows "Add this Mac to Agent Keyring?" on Home; Add, after Face ID, lists both, seals a copy of every password it holds to the Mac, writes the new Members and the copies to iCloud, and replaces its invitation. The Mac takes the list only from the revision that names it with its own keys, signed by the inviting iPhone, each later one checked against the one before, then reads every record in iCloud again for the catalogue, vault and copies it passed over. Don't Add deletes both records, which the Mac reads as not added; ten minutes with no answer is the same. A new iPhone joins an iPhone's list the same way, with one request.

A joiner already in the members list with exactly these keys is approved at once, so a join that missed its answer still hears it. Joins are not saved: after a restart the joiner asks again.

## The Mac's lists

Written by AI on 2026.11.21 by model claude opus 5.5. Code: `MacSyncCoordinator.swift`.

Kept in the app's keychain (`MacKeychainStateStore`): the signed members list and every revision of it, the signed catalogue as last signed here or on the iPhone, the copies revision, and each device's signed push registration (the newest for each device wins; an iPhone registers its Watch's). The push key from `agent-keyring push-key` is in the same keychain. The sealed copies are in `MacVaultFileStore`.

- **A computer's bundle** (`MacSyncCoordinator.bundle(for:holding:)`, in its update mailbox, its JoinStatus and each answer) gives the members list, every revision after the one it holds, the catalogue, the push registrations, its own Automatic copies and a Freshness. Only copies of the signed catalogue's current version are given, never a Blocked one, so copies from an import he has not yet approved sending stay on the Mac.
- **From the iPhone, through iCloud**: a members list, checked against the one held (a device or computer it leaves out keeps no copy or push registration here); a catalogue, when a rule changed there; copies, each checked against its signer and the catalogue's version. Agents' complaints on this Mac are kept in one owner-only file and shown on no screen.
- **A rule changed on the iPhone** arrives as the catalogue only. The Mac takes its rules, withdraws every computer's copies of a password no longer Automatic, and if a computer allowed Automatic passwords lacks a copy of one, the panel asks for Touch ID to make them (`automaticCopiesMissing`, read from the copies after each catalogue and after the copies are made; "Not now" clears it until the next catalogue).
- **The rev push**: whenever the members, the catalogue or any copy changes, the iPhone gets a silent push a second later (collapse id "rev") and reads iCloud. Nothing depends on it arriving.
- **iCloud** (1.1, `CloudReplicaSyncCoordinator.swift`, `MacCloud.swift`): two seconds after any change, the Mac writes the signed members list (with its history), the signed catalogue, its own push registration, its vault (signed with its reply key) and the copies it sealed for each other device. Members and the catalogue are written only if newer than the record there; otherwise the Mac takes that one. It pulls on launch, on coming to the front, and on CloudKit's push, and checks every record as above: Members revision by revision (a list that does not name a Mac with no list yet is another vault, and left alone), push registrations, the catalogue, copies (a copy sealed to this Mac by another device is kept beside its own, the newest used), and other devices' vaults, folded into its own list without their rules. Copies of a version the catalogue does not list yet are tried again after the next pull.

## The Mac's own requests

Written by AI on 2026.11.21 by model claude opus 5.5; through answer boxes and grants on 2026.11.24. Code: `AgentKeyringEngine/Mac/MacOutgoingApprovalRequests.swift`, `CredentialLeaseStore.swift`.

When an agent's lease waits, the push key is held and an iPhone or Apple Watch is listed, the Mac signs a request naming a new answer box at its relay. The reason is cut to 400 bytes and the agent, project and task to 100, so the push fits Apple's 4 KB. The Mac saves the link from the lease to that request in the lease store, pushes it through Apple to every device with a push registration, and reads the answer box until it is answered or a little after its time. The lease store and devices use the same lease states:

| State | Reached by | Push |
|---|---|---|
| waiting | The agent asks | Visible request |
| approved | Touch ID in the panel, or a device answers with delivery that opens with this Mac's receiving key. The Mac puts the grant at the relay. | Approval with the deciding device |
| denied | Deny in the panel, or a device denies in the answer box. The denial hold applies. | Denial |
| unanswered | Nobody answers within ten minutes. | Outcome |
| cancelled | The agent stops asking. | Outcome |
| released | The agent releases its approval. | Outcome |
| expired | The approval window passes. | Outcome |
| ended | The user stops access, the rule or login changes, or the Mac restarts and loses the opened password. | Outcome |

Each change is one silent push per device, in order with the request's other pushes. The first answer wins: an answer from a device not in the members list, or over other bytes, is refused and logged. Apple's acceptance is kept as how far it has got. Before every use of an approval its grant is read (`checkNotStopped`): a Stop signed by a device in the list ends the lease for good; a relay that cannot say refuses that use only. After a restart the Mac reads the saved links: a lease still pending reads its box again, and one that ended meanwhile is told once. The link goes when the lease ends.

A practice request is the same with no lease. It has its own state (waiting, then approved, denied, or unanswered after ten minutes); only the device it names may answer it; and an approval needs no delivery.

## Another computer's request on the Mac

Written by AI on 2026.11.21 by model claude opus 5.5; through pushes and answer boxes only, with the doors cut, on 2026.11.24. Code: `AgentKeyringEngine/Mac/MacRemoteAsks.swift` (the record), `MacCloud.receivedPush`, `AgentKeyringScreenBackends/RemoteRequestBackend.swift` and `AgentKeyring/ApprovalPresenter.swift` (the panel), `LeaseBackends.swift` (Stop in the menu bar). Tests: `MacBoxTests.anotherComputersRequestIsApprovedHereAndCanBeStoppedHereForItsThirtyMinutes`, and the Mac's cases in `TestAnAgentAsksAndJoshAnswersFromHisIPhoneWatchOrMac`.

The computer an agent asks from pushes its request to this Mac as it pushes it to the iPhone and Apple Watch: a silent push, whose notice this Mac opens with its notice key. The asking computer owns the request: the record here only follows it. One value per request id, `MacSyncCoordinator.remoteAsks`, not saved:

| State | Reached by | Next |
|---|---|---|
| (none) | a push whose request is signed by a computer in the members list, names an answer box at a relay this Mac may use and a password in the signed catalogue that is not Blocked, and is neither Automatic nor a practice request | waiting |
| waiting | Touch ID in the panel: this Mac opens its own copy, seals it to the computer's receiving key for 30 minutes, signs the answer with its signing key and puts the AnswerUpload, with its lists, in the request's answer box; Deny, with or without words: an answer signed with the reply key, put the same way | waiting, shown as sending until the outcome's push |
| waiting | the outcome's push from the same computer | ended(that Lease) |
| waiting | `answer_by` passes | ended(unanswered) |
| ended(approved) | the computer's later outcome (released, out of time), or Stop here | ended(that Lease) |
| ended(approved) | the approval's 30 minutes run out | (none) |
| ended(anything else) | a minute passes | (none) |

What must always be true:

- **It is shown in the usual panel, the same way as this Mac's own agents' requests**, oldest first among them, with the computer's name ("Codex on Linux server wants"). With the lid shut, its panel says to answer on the iPhone or Apple Watch, because the computer pushed it there.
- **The first answer wins, in the answer box.** A late Touch ID or Deny here finds the box taken, says another device answered first, and sends nothing. A request already ended here sends nothing.
- **An approval stays for its 30 minutes, so Stop here works in all of them.** Stop in the menu bar marks the request's grant at the relay stopped, with this Mac's signed EndRequest; the computer refuses every use after. A late "no answer" from the panel's own timer never undoes an approval.
- **The hold after a denial is the asking computer's.** Nothing here holds the password off, and "Let it ask again" lifts nothing.
- **An answer that cannot reach the relay is not an answer.** The put retries for 30 seconds; then the panel says the computer was not reached, and the request still waits for Touch ID again or an answer on the iPhone.

Known and left alone: an approval by the Apple Watch shows as "Approved", not "Approved on your Apple Watch": the panel's values have no Apple Watch. An Automatic use on another computer is not shown here, so it is stopped from the iPhone or Apple Watch.

## iPhone: first run

Code: `PhoneFirstRun` in `AgentKeyringPackage/Sources/AgentKeyringApprovalCore/PhoneFirstRun.swift`. `PhoneKeyringEngine` sends it events and does what each state asks. Tests: `PhoneFirstRunTests`.

The iPhone joins a Mac, or another iPhone, through iCloud, with the join card that device left in iCloud Keychain (see Joining the Mac). Set Up on This iPhone skips the Mac altogether: the iPhone signs its own Members, with only itself, and an empty catalogue, after Face ID, or, if these keys already signed a list in iCloud (the app was reinstalled), takes that list back. The iPhone makes its own practice requests (`PhonePractice.swift`), pushed through `push.opentrawl.sh` and answered in a box, so practice needs no Mac. Each state is one screen; the pages themselves are built from the shared page parts.

### States

| State | Screen |
|---|---|
| `searching` | Reading iCloud Keychain for another device's join card, for three seconds at most. |
| `welcome` | No card: "Welcome to Agent Keyring", with Set Up on This iPhone and "Already set up on your Mac?". The look goes on, so a card that arrives later moves it to `foundMac`. |
| `trouble` | "Check these four things", with Try Again and Back. |
| `foundMac(name)` | "Continue setup from <Mac>", with Connect and Set Up on This iPhone. Nothing is asked of the Mac yet. |
| `waitingForMac(name)` | The request to join waits on the Mac, with Cancel. |
| `deniedByMac(name)` | The Mac refused, with Ask Again and Cancel. |
| `cantReachMac(name)` | iCloud is not available, or the request to join could not be put there, with Try Again and Cancel. |
| `expired(name)` | Ten minutes with no answer from the Mac, with Ask Again and Cancel. |
| `receivingPasswords` | This iPhone's copies arriving from the device that added it, with how many of how many. |
| `importPasswords` | Set up on this iPhone: "Copy your passwords" from Passwords on this iPhone, with Turn On in Passwords and Skip for Now. |
| `notifications` | "Turn on notifications" with the checklist, ticked from what iOS allows: Turn On Notifications until iOS has asked, then Continue, with Open Settings while a box is unticked. |
| `askingNotifications` | iOS's own question, over the same screen. |
| `notificationsOff` | Notifications are off, with Open Settings and Continue Without Notifications. |
| `practiceOffer` | Send Practice Request, Skip for Now. |
| `practiceWaiting(id, arrived)` | Waiting for practice request `id`; `arrived`: it is here and its notification waits for a tap. |
| `settingUpNotifications(id)` | 30 seconds and Apple has given no push address, with Skip for Now. |
| `practiceNotArrived(id)` | 30 seconds and nothing arrived, with Try Again and Skip for Now. |
| `practiceMacUnreachable(id)` | The practice request could not be sent (its name is from when the Mac made them, and it is saved), with Try Again and Skip for Now. |
| `practice(id)` | Practice request `id`, open as a sheet. |
| `practiceResult(outcome)` | Approved, denied or no answer, with Send Another and Continue. It stays until he goes on. |
| `readyOfferWatch(watchToAdd)` | "Add your Apple Watch?" with Add Apple Watch and Done when a Watch is paired and not added; otherwise Done. |
| `addWatch` | The Apple Watch flow (below) runs; when it closes, `finished`. |
| `finished` | The app's tabs, Home first. |

### What must always be true

- First run has one state, saved on every change. Every first-run screen and every step the app takes in it follow from that state alone.
- Nothing asks the Mac before Connect: the join is put in iCloud only in `waitingForMac` (`mayJoin`). The look for the card is a local read every three seconds, before Connect and while waiting (`looksForMac`).
- While it waits, the iPhone reads the `members` record every three seconds. Leaving the app cuts the wait; `waitingForMac` is saved and the wait goes on on return. iCloud not available is `cantReachMac`.
- Cancel takes the request out of iCloud; refused (the inviter took the request away without adding it) and expired (ten minutes) come from what iCloud holds. None of the three asks again by itself: only Ask Again or Try Again. Test: `refusalAndExpiryWaitForHim`.
- A practice request has one id, chosen by this iPhone and saved. This iPhone makes it, and the same id rejoins it; if one is waiting already, first run takes its id (`practiceSent`). A new id is made only by Send Practice Request, Send Another or Try Again. Test: `practiceKeepsItsID`.
- After a relaunch, any practice state becomes `practiceWaiting(id, false)`; the result stays until he goes on. Test: `resultStays`.
- An event the table does not list for a state leaves the state unchanged.
- Timers stay outside the machine and arrive as events: three seconds for `noMacFound`, 30 seconds for `practiceTimedOut`, and a minute with no new copies ends `receivingPasswords` (the rest come with the next fetch).

### Transitions

| From | Event | To |
|---|---|---|
| any | `removed` (this iPhone left the list of devices) | `searching` |
| `searching`, `welcome` | `macFound(name)` | `foundMac(name)` |
| `searching` | `noMacFound` | `welcome` |
| `welcome` | `havingTrouble` ("Already set up on your Mac?") | `trouble` |
| `trouble` | `tryAgain` | `searching` |
| `trouble` | `cancel` (Back) | `welcome` |
| `foundMac` | `macGone` | `searching` |
| `foundMac(name)` | `connect` | `waitingForMac(name)` |
| `waitingForMac`, `deniedByMac`, `cantReachMac`, `expired` | `cancel` | `foundMac(name)` |
| `waitingForMac` | `joinRefused` / `macUnreachable` / `joinExpired` | `deniedByMac` / `cantReachMac` / `expired` |
| `deniedByMac`, `expired` | `askAgain` | `waitingForMac` |
| `cantReachMac` | `tryAgain` | `waitingForMac` |
| `waitingForMac` | `joined` | `receivingPasswords` |
| `searching`, `welcome`, `trouble`, `foundMac`, `cantReachMac` | `setUpHere` | `importPasswords` |
| `importPasswords` | `passwordsImported` (the copy is sealed and signed, or Skip for Now) | `notifications` |
| `receivingPasswords` | `passwordsReceived` | `notifications` |
| `notifications` | `continueTapped` | `askingNotifications` |
| `askingNotifications`, `notificationsOff` | `notificationsAnswered(true)` | `notifications` (the checklist stays) |
| `notifications` | `notificationsDone` (Continue) | `practiceOffer` |
| `notifications`, `askingNotifications` | `notificationsAnswered(false)` | `notificationsOff` |
| `notificationsOff` | `continueWithoutNotifications` | `practiceOffer` |
| `practiceOffer`, `practiceResult`, `practiceNotArrived`, `settingUpNotifications`, `practiceMacUnreachable` | `sendPractice(id)` | `practiceWaiting(id, false)` |
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

Code: `PhoneAddWatch` in `AgentKeyringPackage/Sources/AgentKeyringApprovalCore/PhoneAddWatch.swift`; `PhoneKeyringEngine` holds the Face ID confirmation and does the work. Tests: `PhoneAddWatchTests`. The same flow opens from the end of first run and from Add Apple Watch in Devices.

| State | Screen |
|---|---|
| `notPaired` | No Apple Watch is paired with this iPhone, with Close. |
| `watchAppMissing` | Install Agent Keyring on Apple Watch, in words (no app can open Apple's Watch app at Available Apps), with Check Again; it also moves on by itself when WatchConnectivity says it is installed. |
| `faceIDFirst` | Why adding it needs Face ID, with Continue with Face ID and Cancel. |
| `waitingForWatch(until)` | "Confirmed with Face ID · ready until 14:17", "Now tap Add on your Apple Watch", with Cancel. |
| `faceIDExpired` | The confirmation ended, or iOS closed the app: Continue with Face ID again, with its reason. |
| `watchNeedsPasscode(until)` | Apple Watch has no passcode (from its self-test), with Try Again. |
| `encrypting(done, total)` | This iPhone encrypts a copy of each password for Apple Watch. |
| `copiesFailed(reason)` | Apple Watch is listed but did not say it holds its copies, or this iPhone lacks some, with Try Again (copies only) and Cancel. |
| `added` | Apple Watch added, with Done. |
| `closed` | The flow is over. |

What must always be true:
- Face ID comes first, after the page says why. Nothing is decrypted until Apple Watch asks: the authenticated LAContext is held, with its end shown (`PhoneAddWatch.hold`, ten minutes), and used for the key operations then. Face ID is asked again, with its reason, only if the end passes or iOS closed the app; never twice in a row otherwise. Test: `confirmationIsHeldThenLapses`.
- Apple Watch offers Add only while the iPhone waits: the iPhone sends the confirmation's end to the Watch (`addUntil`) and withdraws it when the wait ends.
- If Apple Watch asked before Face ID (its keys arrived first), adding goes on as soon as the confirmation is given.
- Adding lists Apple Watch, then sends it its own copies, one generation as one file over WatchConnectivity (`WatchCopies`, `PhoneWatchCopies.swift`), and waits up to two minutes for the Watch to say it holds that generation. Copies the Mac sealed for the Watch reach the iPhone through iCloud as ciphertext only the Watch can open; no computer or relay is given them. If the Watch does not say so, it stays listed and Try Again sends only the copies, with the held confirmation or a new one. Test: `copiesFailedIsExplicit`.
- After that the iPhone sends a new generation whenever the Watch's copies change: a copy from Passwords here, the Mac's copies for the Watch arriving through iCloud, a rule changed or a password Blocked. The Watch replaces what it held with each generation, ignores an older one, drops a Blocked or changed password at once when a newer catalogue arrives, and deletes all of them when it leaves the list, keeping only the generation, so a file sent before the removal never brings them back; it takes no file while its list does not name it. A Watch added in 1.0, which holds none, is never sent an empty generation while this iPhone holds passwords: its copies are sealed at the next Face ID here.

## iPhone: every day

Code: `PhoneHomeView`, `PhoneLoginsView`, `PhoneDevicesView` and `PhoneSettingsView` in `PhoneHomeTab.swift`, `PhonePasswordsTab.swift`, `PhoneDevicesTab.swift` and `PhoneSettingsTab.swift` under `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone/`. These screens hold no state of their own: each shows the snapshot, and each button sends one call.

- The iPhone learns of a request only from its push: the notice in it carries the request. The app reads the notice when the notification arrives with the app in front, when it is opened, and, on coming to the front, from every notification still in Notification Centre. Nothing depends on dialling the iPhone.
- It keeps its own copy of every password that is not Blocked: from iCloud (`PhoneVault.swift`) and from its own exports, fetched on coming to the front and on CloudKit's or the Mac's silent push. Per password it keeps the copy of the catalogue's current version, a new one before one held (`receiveSealedCopies`).
- Copy from Passwords (Passwords tab, and first run's `importPasswords`): the export is merged into this iPhone's own vault with `VaultSnapshotMerger`, every login's secret sealed to this iPhone, to every other device, and, if Automatic, to every computer; the new catalogue is signed after one Face ID and written to iCloud, with the vault and the copies for the other devices. If another device signed a newer catalogue meanwhile, this iPhone takes it and signs again, once.
- Add Another Computer (Devices): a one-time code with its `agent-keyring enrol` command and a QR code; the computer's request through the code's box; Face ID; the new Members; the computer's Automatic copies, in the JoinStatus. Each answer this iPhone sends in a box carries the lists, and an approval also that computer's own Automatic copies, so the computer keeps up. A computer's copies made here go when its password is no longer Automatic, and iCloud drops them with the next share.
- The reminder to copy again: off until he turns it on in Settings; then one local notification once the newest copy (from any device) is a week old, set again at every copy and launch. Approve opens its own copy after Face ID, checked against the signed Catalogue; if it has none, it fetches once, and if iCloud cannot be reached it says the password is not on this iPhone yet.
- Answers go in the request's answer box, named in the signed request, at the default relay or the one set on this iPhone (`CredentialSealing.verifySignedLeaseRequest`, `AnswerBox.answer`); Stop marks the request's grant there (`AnswerBox.stopLeaseGrant`). An answer the relay does not take at first is retried for 30 seconds (`AnswerBox.retryFor`) and shown as not delivered yet meanwhile (`PhoneSnapshot.undelivered`). A box says only that it took the answer, so the request shows as sending until the outcome's push.
- Home: Ready, or the one line that says what is wrong (still connecting; signed out of iCloud). Devices: Practice on Apple Watch's row makes its practice request; Add Apple Watch while a Watch is paired and not added; Remove on every row except this iPhone and a Mac's computer row.

### Facts that are not first run's state

- `pushRegistered`: this launch's push address is registered (signed with the reply key) and shared.
- `pushSeen`: a push has reached this iPhone. It is saved.
- `facts` (`PhoneNotificationFacts`): what iOS allows (notifications, banners, Lock Screen, Time Sensitive, in the Scheduled Summary), read each time the app comes to the front and after iOS's question.
- Apple Watch's facts (`PhoneWatchFacts`): paired and app installed (WatchConnectivity), opened, added (listed), notifications, push address and practice answered (its self-test).
- `practiceOutcome`: once approved it stays approved (test: `practiceApprovalLatches`).

### Reachable faults closed

1. **The join asked twice**, 0.03 seconds after opening and again after leaving the app. Now nothing asks before Connect, and a cut call is "still waiting". Test: `joinIsHisAndSurvivesLeaving`.
2. **Two or three practice requests, and "Your answer wasn't sent".** Now the request keeps its id and is rejoined. Test: `practiceKeepsItsID`.
3. **A refused or expired join asked again by itself**, every few seconds. Now each waits for Ask Again. Test: `refusalAndExpiryWaitForHim`.

## Apple Watch: setup

Code: `WatchOnboardingStep` in `AgentKeyringPackage/Sources/AgentKeyringSealing/Watch/WatchOnboardingStep.swift`. `WatchLink.refreshSetup` works it out and `WatchHome` shows it. Test: `WatchSetupTests`.

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
- Try Practice asks the iPhone, which makes the Watch's practice request; a practice that has not come within a minute is offered again. Its card has Deny, Approve and Deny and Explain, like any request.
- The Watch keeps its own copies, sealed to its Secure Enclave and sent by its iPhone over WatchConnectivity (`WatchCopies`); those the Mac sealed pass through iCloud as ciphertext only the Watch can open, and nothing sends them to a computer or the relay. A request's push carries no copy.

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

The log has a line when the card is shown (`card shown`, with the request, and how many seconds it waited for the list of devices if it had to) and when it cannot read the request (`card unreadable`, with the error). With the extension's `push named`, that times each request from the push to his wrist.

What must always be true:
- An answer goes only to the request on screen, and only once: `respond` works only from `showing`.
- The retry that reads the request again while the list arrives is cancelled when another notification takes the card, and when the card closes.

## iPhone: request sheets and notifications

Written by AI on 2026.11.21 by model Gemini 4 Neon. Code: `PhoneSheetState` in `AgentKeyringPackage/Sources/AgentKeyringApprovalCore/PhoneSheet.swift`, `PhoneModel` in `PhoneModel.swift`, `PhoneRequestView` in `PhoneRequestView.swift`, `PhoneRootView` in `PhoneRootView.swift`, `PhoneAppDelegate.answer` in `AgentKeyringPhoneApp.swift`. Tests: `PhoneSheetTests`.

`PhoneRootView` owns **exactly one** `.sheet(item:)` modifier, driven strictly by `PhoneSheetState`. First-run practice requests and everyday agent requests share the exact same sheet state machine, eliminating competing `.sheet` modifiers and ghost double-popups.

| Presentation | Mode | Screen |
|---|---|---|
| `none` | | Home (all waiting requests queued in `Waiting for you`, with optional `staleNotice` banner if a tapped notification already ended) or first-run page |
| `request(id, mode, canReturnToDecide)` | `decide` | Normal tap on a notification or `Answer It Here`: Approve with Face ID (green), Deny (red), Deny and Explain (link). Cancel dismisses cleanly (for practice, sends `practiceDismissed` back to `practiceWaiting(id, arrived: true)` with `Answer It Here` and `Send Another`) |
| `request(id, mode, canReturnToDecide)` | `approving` | Direct `Approve` action from a held notification: clean request header and `Approving…` status (never flashes a Deny form). Passes `reusingUnlock: true` to both real and practice approvals. Cancelling Face ID falls back cleanly to `decide` |
| `request(id, mode, canReturnToDecide)` | `explain` | `Deny and Explain`: compact top summary card so the reply box and microphone stay clear above the iOS keyboard, `Deny and Send`, and `Approve Instead`. Back returns in place to `decide` when opened from `decide` |
| `addWatch` | | Adding Apple Watch from Devices after first run |

What must always be true:
- **Exactly one modal sheet exists at any time.** `PhoneSheetItem` is keyed by `request:\(id)` (not by mode), so moving `decide` <-> `explain` <-> `approving` for the same request updates in place with zero sheet dismiss/re-present bounce.
- **Reply drafts are scoped per request ID** (`drafts[id]`), never a single global string. Switching from Request A to Notification B preserves A's draft and starts B empty; ending A clears only `drafts[A]`.
- **Incoming notifications never steal focus.** New waiting requests appear in Home's queue and do not interrupt an open sheet.
- **Tapping an already-ended notification** opens no empty sheet and sets `staleNotice` explaining how the request ended.
- **Step 2 (`Turn on notifications`)** shows neutral pending status (`Notifications not yet allowed`) before iOS has been asked and offers `Skip for Now` (`continueWithoutNotifications`).

## Notifications on the iPhone and Apple Watch

- A request's notification goes when it is answered on this device, and when this device learns it has ended (the asking computer's silent push for every outcome), and never comes back as a separate "Approved on your iPhone" notification. The silent push carries the request id at the top level (`"id"`) and no alert.
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
