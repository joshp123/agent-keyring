---
written_by: ai (Claude Opus 5.5, 2026-10-12), from Josh's direction
---

# iPhone approval: design specification

## Direction

Swiss, not soft: an International Typographic Style screen on iOS 27. That means objective information, a strict left-aligned grid, hierarchy carried by type size and weight rather than boxes and tints, hairline rules instead of cards, and colour used only where it means something.

The interaction is the one people already know from Okta Verify and Apple's "Allow / Don't Allow": one question, two strong buttons. We improve on it by showing evidence. Who is asking, from where, why, and on behalf of which of your requests.

One screen does everything. When a request is pending, it owns the top of the screen; below it, and when nothing is pending, sits a quiet activity log.

## Type

SF Pro only, with Dynamic Type styles and no custom sizes, so it scales for accessibility.

| Role | Style | Weight |
| --- | --- | --- |
| Question ("Claude Code wants to sign in to github.com") | `.title2` | `.semibold`, tracking −0.4 |
| Section label ("Agent", "Why", "Your request") | `.footnote` | `.regular`, `.secondary` |
| Fact values (agent, machine, folder, address, account) | `.body` | `.regular`; site and agent `.semibold` |
| Agent claims ("why", "your request") | `.body` | `.regular`, in typographic quotes |
| Expiry | `.footnote`, `.monospacedDigit()` | `.medium`, with `.contentTransition(.numericText())` |
| Activity rows | `.subheadline` | `.regular`; time in `.secondary` |

Left-align everything. No centred blocks except the empty state.

## Colour

Near-black ink on white, inverted in dark mode. Three meaningful colours, each used for one thing only:

| Colour | Light | Dark | Means |
| --- | --- | --- | --- |
| Approve green | `#1A7F37` | `#2EA043` | Approve button, verified seal, "Approved" in the log |
| Deny red | `#CF222E` | `#F85149` | Deny button, unverified badge, "Denied" in the log |
| Signal blue | `#0A4BD6` | `#4C8DFF` | Links, the expiry countdown, the dictation button |

Never a pastel tint, beige, gradient or glass on content. Liquid Glass belongs only to system chrome: the toolbar and sheets, which iOS 27 gives us for free. White text on both buttons must meet WCAG AA contrast.

## Grid and rhythm

- 20 pt side margins, with one column of content.
- Facts are a two-column definition list: the label column is a fixed 88 pt in `.secondary`, values align on one vertical line, and 0.5 pt hairlines (`Color(.separator)`) separate groups.
- Vertical rhythm is in multiples of 4. Use 24 pt between groups and 8 pt between a label and its value.
- Corners: 12 pt continuous on buttons and nowhere else.

## The request

Top to bottom:

1. **Status line.** "Sign-in request" in blue `.footnote` on the left; "Expires 4:52" on the right.
2. **Question.** "<Agent> wants to sign in to <site>." The field is part of the sentence when it isn't a password, for example "wants your two-factor code for github.com".
3. **Facts block** (hairline above and below):
   - **Agent:** "Claude Code" plus a seal.
     - Verified: `checkmark.seal.fill` in green, then "Verified (Anthropic)" in `.secondary`.
     - Unverified: `exclamationmark.shield.fill` in red, then "Unverified" in red.
   - **Machine:** "Josh's MacBook Pro", with the address in `.secondary`.
   - **Folder:** `~/code/nixos-config`, middle-truncated.
   - **Account:** "josh".
4. **Claims block.** A label reads "Claude Code says". Below it:
   - **Why:** "…"
   - **Your request:** "…"

   These are quoted, `.body`, and limited to 3 lines with "More" to expand.
5. **Flags,** only when present. Plain `.footnote` lines with an SF Symbol each, no capsules:
   - `sparkles` "First request from this agent for this login"
   - `lock.shield` "Marked sensitive"
   - `exclamationmark.triangle` "6 requests in 10 minutes"
6. **Actions,** pinned to the bottom safe area:
   - Two equal filled buttons, 52 pt high: **Approve** (green, with a `faceid` glyph) and **Deny** (red).
   - Below them, a full-width plain button in red: **Deny with a note…**

## Deny with a note

- **Presentation:** a medium-detent sheet titled "Tell Claude Code why", with a text editor and the keyboard up.
- **Dictation:** a blue `mic.fill` button on the editor's trailing edge uses Apple's native dictation (Speech framework). It shows a live transcript with a pulsing `waveform` symbol while listening.
- **Buttons:**
  - **Deny and send** (filled red) is the primary action.
  - **Approve and send** is a secondary plain button for "yes, but…".
- **Footnote:** "Your note goes to Claude Code with the decision."

## When nothing is pending

- **Header:** the large title "Agent Keyring", then "Paired with Josh's MacBook Pro" with a green dot, in `.secondary`.
- **Activity:** a plain list grouped by day. Each row shows the time, agent, site and result word ("Approved" in green, "Denied" in red, "Expired" in `.secondary`). Tapping a row shows that request's full facts and claims, read-only.
- **Empty state:** centred `key.horizontal`, with the line "Requests from your agents appear here."
- **Toolbar:** a `gearshape` item opens Details (iCloud, notifications, pairing, key fingerprint).

## Motion and feel

- **Arrival:** a pending request springs in from the top (`.spring(duration: 0.35, bounce: 0.1)`).
- **Approve:** success haptic, then the seal draws on (`.symbolEffect(.drawOn)`) and the request collapses into the log.
- **Deny:** error haptic, same collapse.
- **Expiry:** at expiry the buttons disable, and the status line reads "Expired. The agent was told."
- **Reduce Motion:** respected everywhere.

## Lock-screen notification

- **Title:** "Claude Code wants github.com"
- **Body:** "josh · password · Verified" or "Unverified"
- **Actions:** Approve (requires Face ID), Deny, and Deny with a note (opens the app on the sheet).
