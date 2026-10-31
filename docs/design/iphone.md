---
written_by: ai (Claude Opus 5.5, 2026-10-31; updated for release 4 the same day); replaces iphone-approval.md
---

# iPhone app

## What it is for

1. **Answer requests when you're away from the Mac.** Almost every visit starts from a notification. This is the job the design is built around.
2. **Show what happened.** What agents are using now, with a way to end it, and what they asked for before.

The phone holds no passwords and imports nothing. Your Mac keeps them and delivers the login; the phone only answers, with Face ID.

Everything else (pairing, the phone's key, notification status) sits behind Settings.

It is one screen. A waiting request opens over it; past requests open from it.

## Screens

### Home

Large title "Agent Keyring", Settings in the toolbar, then up to four groups:

- **Waiting for you.** Site, agent and machine, time left. Tap to answer.
- **In use now.** Site, agent and machine, minutes left, and **End now** in red.
- **Nothing waiting.** Shown when neither of the above has anything. It mentions the Lock Screen only once a notification has really arrived: "When your Mac asks this iPhone, the request appears here and on your Lock Screen." Before that: "…appears here. Notifications aren't set up yet, so open Agent Keyring to check." (or "Notifications are off").
- **Today, Yesterday, then dates.** Time, site, agent and machine, and one coloured word: Done, Denied, Blocked, Expired, Unanswered, Automatic.

Screens: `screens/phone/home-*.png`, `nothingWaiting-*.png`, `notificationsOn-*.png`.

### Request

The screen a notification opens. Top to bottom:

1. **Waiting for you** and a countdown ("4:10 left"), in blue.
2. **The question.** "Codex on Mac mini wants to sign in to" (the agent and the machine it runs on), then **github.com** in the largest type on the screen, then "as josh@example.com". For a program: "Claude Code wants to give gh the password for". When the value goes to the agent's own code: "Codex wants the password itself for".
3. **Facts Agent Keyring saw.** Machine (name and tailnet address) and Access ("Sign-in only, up to 30 min", "Password to gh, up to 30 min" or "Password to Codex's own code, up to 30 min"). For a program, the exact command too.
4. **What came from the agent.** "Codex says", its reason in quotes behind a rule, "Working in ~/code/invoices", and "From the agent. Agent Keyring can't check it." The agent's name and folder come from the requesting process, which can say anything, so they sit here rather than in the facts.
5. **Answers,** pinned under your thumb: **Deny** (red) and **Approve** with the Face ID glyph (green), equal width. Under them, **Deny and reply…** in red.

Screens: `request-*.png`, `requestForProgram-*.png`, `requestForAgentProcess-*.png`.

### Deny and reply

Tapping **Deny and reply…** swaps the two buttons for a reply box, in place, so the request stays in view. Type, or use the keyboard's own dictation key. Buttons: **Cancel** and **Deny and send**. The reply reaches the agent with the denial.

Screen: `reply-*.png`.

### After you answer

The buttons become one sentence with a symbol, and **Done**:

| State | Copy |
| --- | --- |
| Sending | The pressed button keeps its colour and shows a spinner; the other fades. |
| Waiting for your Mac | Your answer reached the relay, and your Mac hasn't acted on it yet: "You approved. Waiting for your Mac to deliver it." or "You denied. Waiting for your Mac to pass your reply to Codex." Your reply stays in view. |
| Approved | "Approved. Codex can use it until 01:53, or until it says it's done." Plus **End now**. |
| Denied | "Denied. Codex got your reply." and "You replied: “…”". Without a reply: "Denied. Codex was told." |
| Unanswered | "Nobody answered, so Codex stopped waiting." |
| Withdrawn | "Codex stopped asking before you answered." |
| Expired (lease) | "Ended at 02:14 after 30 minutes. Codex has to ask again." |
| Done | "Codex finished with it at 01:20." |
| Ended | "You ended it at 01:31." Also used when you block the login or the machine. |
| Blocked | "Blocked by this login's rule. You weren't asked." |

If the answer can't be sent: an alert, "Your answer didn't reach Agent Keyring. Try again.", and the request goes back to waiting.

Screens: `sending-*.png`, `waitingForMac-*.png`, `approved-*.png`, `denied-*.png`, `unanswered-*.png`.

### Past request

The same question, facts and claim, the outcome sentence, and **What happened**: a timed list such as "Codex asked on Mac mini", "Sent to this iPhone after 2 minutes", "You approved with Face ID", "Filled the one-time code". **End now** while it is in use.

Screens: `inUseDetail-*.png`, `historyDetail-*.png`.

After a denial, Agent Keyring refuses new requests for that login from that machine for 30 minutes, so an agent can't wear you down by asking again. The past request says so ("New requests from this machine are held off until 06:44.") with **Let it ask again**, for when you change your mind.

### Unreachable

When the phone can't reach Agent Keyring, a line at the top of Home: "Can't reach Agent Keyring on Mac mini. Since 01:15. Requests can't reach you until it's back. Check Tailscale is on. Retrying." It retries by itself; there is no button. Requests and history stay below it.

Screen: `unreachable-*.png`.

### Settings

- **Requests:** which Agent Keyring the phone talks to and when it last heard from it, and when it last checked the rules ("Rules · Checked 11 minutes ago"). Footer: "A request shows on your Mac first. If you don't answer there in time, or your Mac is locked, it comes here. The delay is set on your Mac." The phone doesn't show the delay itself: the Mac runs it and the phone never learns it.
- **This iPhone:** notifications ("Not set up yet" until a notification has actually arrived, "Off in iPhone Settings", or "On"), and the key fingerprint: "Your approvals are signed with this key, which never leaves the iPhone's Secure Enclave."

Screen: `settings-*.png`.

### Pairing

Until the phone is paired, Home starts with "Not paired yet, so requests can't reach this iPhone" and **Pair**; Settings has "Pair with your Mac".

The pairing screen takes the relay's address, prefilled `mac-mini:17443`. It then shows the code to compare with the Mac's, in the same two rows of four groups the Mac shows, and "When every group matches, approve on your Mac with Touch ID. This iPhone carries on by itself." There is no confirm button on the phone: the Mac's signed approval is the confirmation. **Doesn't match** cancels. A failure shows the reason and **Try again**.

Screens: `pairing*.png`, `homeNotPaired-*.png`, `settingsNotPaired-*.png`.

## Notifications

A notification says a request is waiting. Tapping it opens the request screen; every answer is given there, with Face ID. There are no Approve or Deny buttons on the notification itself.

## Decisions, and why

- **No "verified agent" badge and no warning flags** ("first request", "6 requests in 10 minutes", "sensitive"). Josh called the flags theatre on 12 Oct, and the requester check behind the badge was removed. The screen shows what Keyring observed and labels the rest as the agent's claim.
- **The site is the headline,** not the agent. You approve a login, so the login is the thing to read first.
- **Deny is never weaker than Approve.** Same size, same weight, red against green, side by side.
- **The reply is a kind of denial.** Josh: "the reply thing needs to be more of an obvious deny". There is no "approve with a note".
- **Inline reply, not a sheet.** A sheet over the request hid what you were replying to and showed the buttons through its glass.
- **24-hour times** everywhere.

## Built and not built

The screens are real SwiftUI in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Phone`, fed by `PhoneKeyringModel`, which follows `PhoneKeyringBackend`'s update stream. The release 4 phone backend (`AgentKeyringPhone/PhoneImportBackend.swift`) feeds them in the app; launch with `-designScenario <name>` to open any state on mock data. `real-*.png` is the app with nothing paired.
