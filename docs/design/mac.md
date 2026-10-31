---
written_by: ai (Claude Opus 5.5, 2026-10-31)
---

# Mac app: approval, menu bar and rules

The Mac does three things: lets you answer a request with Touch ID when you're at the keyboard, shows what agents are using now, and sets each login's rule. Import and setup stay in the main window, which this note doesn't change.

## Approval panel

A request that asks you appears first on the Mac, as a small borderless panel at the top right, under the menu bar, on the screen with the pointer. It shows the same things as the iPhone, in the same order: the question with the site largest, the facts Agent Keyring saw (machine, access, and the command for a program), and what came from the agent (name, reason, folder), labelled as such.

- **Approve** (green, Touch ID glyph) and **Deny** (red), equal width. **Deny and reply…** under Deny; "1 more waiting" on the right when requests queue.
- **Touch ID is the approval.** Where the backend allows it, the panel shows the live Touch ID glyph ("Touch ID to approve") and starts Touch ID as it opens, so touching the sensor approves with no click; Deny stops it. Otherwise Approve is a button that brings up the system Touch ID or Apple Watch prompt. The screenshots show the button form, because the Mac mini has no Touch ID.
- **It never takes focus by itself.** Josh: half of Apple Watch prompts hit while he's typing. The panel is non-activating and has no keyboard shortcuts, so typing into another app can't approve or deny anything. It takes the keyboard only when you click into the reply box.
- **Deny and reply…** swaps the buttons for a reply box with **Cancel** and **Deny and send**; Return sends.
- **After an answer:** the same sentences as the iPhone ("Approved. Codex can use it until 01:07, or until it says it's done.") and **Close**. If Touch ID fails: "Touch ID didn't confirm. Nothing was shared."
- If you don't answer, the request goes to the iPhone after the delay set there (default 2 minutes), and the panel stays until either answers.

Screens: `screens/mac/approval-*.png`, `approvalReply-*.png`, `approvalApproved-*.png`, `approvalDenied-*.png`, `approvalAgentProcess-*.png`.

## Menu bar

The icon is an outline key. While something waits it becomes a filled key with a count, so a waiting request is visible without opening anything.

Clicking it opens a small window:

- **Waiting for you:** site, agent and machine, time left, **Review** (opens the panel).
- **In use now:** site, agent and machine, minutes left, **End** in red.
- "No agent is using a login now." when both are empty.
- **Recent:** the last four answers, with time, site, agent and the outcome word. Right-click a denial that is still holding off new requests to **Let it ask again**.
- Footer: "522 logins · imported 3 days ago", **Rules…**, and a ··· menu with Open Agent Keyring, Check for Updates… and Quit.

Nothing else. Josh, July: "too many options".

Screens: `menuBar-*.png`, `menuBarQuiet-*.png`.

## Rules

A window with a sidebar and a table.

- **Sidebar:** All logins, then the three rules with their counts: **Ask** (blue), **Automatic** (green), **Blocked** (red). **Set rules with AI…** at the bottom opens the existing assistant.
- **Header:** the filter's name and one sentence:
  - Ask: "Agents ask you before each task. New logins start here."
  - Automatic: "Approved without asking. Still recorded, and still ends after 30 minutes."
  - Blocked: "Agents can't use these, and you aren't asked."
- **Table:** Login, Account, Rule, Last used. Sortable, searchable from the toolbar.
- **Changing a rule:** the Rule cell is a menu, so you change it where you read it. For several logins, select them and use **Set Rule** in the toolbar or the right-click menu.
- **Confirming:** on first use, or when the saved rules can't be checked, a band across the top says "Confirm your rules", sums them up ("34 logins: 18 Ask, 9 Automatic, 7 Blocked.") and has **Confirm with Touch ID**. Agents get nothing, and the table is locked, until you confirm.
- **Applying:** after you change a rule, "Applying changes…" with a spinner sits on the title row until the relay acknowledges the change. It needs nothing from you: the Mac keeps sending it, across quits and network loss.

A rule is a property of the login, so it is a column, not a folder you move logins between. That is the "Move credential" confusion from July.

Screens: `rules-*.png`, `rulesAll-*.png`, `rulesConfirm-*.png`.

## Other machines (release 3)

- **Remote requests** use the same panel, with the machine in the question: "Codex on Mac mini wants to sign in to". A local request stays "Codex wants to sign in to", and its Machine line reads "This Mac". Replying to a remote agent shows Touch ID on "Deny and send", because the reply is signed. If the relay is unreachable, an answer says "Saved. It reaches the relay as soon as the relay is back."
- **A machine joining** (after `agent-keyring enrol` there) opens the panel with its name, the tailnet node the relay saw, and an eight-group code in two rows of four. "Doesn't match" refuses; "They match" approves with Touch ID. Automatic logins for it are off unless switched on. Your iPhone joining as an approver looks the same.
- **Machines window**, from the menu bar's More menu: the relay link, answers waiting to send, "Applying changes…" until the relay acknowledges a rule change or a machine you approved or removed, devices waiting to join, devices that can approve, and machines that can ask (each with Remove).
- **First relay setup:** you enter the relay's address, then compare the eight-group code on screen with the relay's code that setup brings from the Mac mini over its trusted SSH connection: "Compare with the relay's code from setup:" and "Setup reads it on your Mac mini and shows it to you." You never open a service log. **Doesn't match** cancels; **They match** confirms with Touch ID.
- **Ask your iPhone after:** under "Can approve requests", once an iPhone can approve. 30 seconds, 1, 2 (the default), 5 or 9 minutes. Footer: "If you don't answer on this Mac by then. When this Mac is locked, it asks your iPhone at once." The setting lives on this Mac; the phone settings point here.
- **Menu bar:** devices waiting to join appear under "Waiting for you" and count in the icon. One line appears when the relay is offline. Applying stays out of the menu bar: it needs nothing from you.

Screens: `approvalLocal-*.png`, `approvalQueued-*.png`, `enrolment*.png`, `machines*.png`, `rulesApplying-*.png`, `menuBarRemote-*.png`.

## Built and not built

The views are real SwiftUI in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Mac`. Since release 2, the Mac app uses all three: the panel answers lease requests in place of the system Touch ID prompt, the menu bar window follows the lease store, and the rules window wraps the existing access-rules controller. RFC 0007 says how, and lists the one-look, one-touch check that proves the panel on the MacBook.

Screenshots come from the design gallery (`Tools/AgentKeyringDesignGallery`) on the Mac mini. Most use mock data; `lease*.png` are mapped from lease records through the same adapter the app uses.
