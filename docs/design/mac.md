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

A rule is a property of the login, so it is a column, not a folder you move logins between. That is the "Move credential" confusion from July.

Screens: `rules-*.png`, `rulesAll-*.png`, `rulesConfirm-*.png`.

## Built and not built

The views are real SwiftUI in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI/Mac`, behind the four backend protocols in RFC 0007, and fed by mock data. The screenshots come from the design gallery (`Tools/AgentKeyringDesignGallery`), which shows the real views on the Mac mini.

The Mac app itself still uses its old menu, rules window and plain system Touch ID prompt. Wiring the new views in is RFC 0007's U2 (approval panel) and U3 (menu bar and rules), as adapters over the release 2 lease store and the existing access-rules controller. RFC 0007 lists what the lease store still needs to supply.
