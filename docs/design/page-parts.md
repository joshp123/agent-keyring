---
written_by: ai (Claude Opus 5.5, 2026-11-21), for the engineers building the pages
---

# Building a page from the parts

Every first-run page, device flow and everyday screen is built from the parts in `AgentKeyringPackage/Sources/AgentKeyringDesign`, and from nothing else. The parts own every margin, gap, colour and type size, so a page cannot come out cropped or hand-made. A check hosts each page at the smallest size each device gives it and fails if any text or button is cut off.

## The rules

1. Every word on screen goes through `KeyringText`. Button labels already do, because `KeyringButton` uses it. A plain `Text`, a raw colour, a padding or a fixed `.frame(height:)` on a page goes round the check.
2. Never clip around text: no `.clipped()`, no clip shape, no fixed height. The window is the only clip, and the check watches it.
3. Blue (`.advance`) moves setup on. Green (`.approve`) and red (`.deny`) only ever approve or deny. Everything else is `.plain` (grey) or `.link` (text).
4. Words come from the copy tables (`SetupCopy`, `PhoneCopy` and the rest). The parts' own words are in `PartsCopy`.

## The parts

| Part | What it is |
| --- | --- |
| `KeyringSetupWindow(heading:steps:mascot:) { page }` | Mac setup window, 760 by 560: step list and mascot on the left, the page on the right. |
| `KeyringPage(step:title:sentence:alignment:mascot:status:primary:secondary:aside:) { body }` | One page. Mac: the buttons sit along the bottom. iPhone: it scrolls, with the buttons pinned at the bottom. Watch: one scrolling column. |
| `KeyringText(words, as: role, fit:)` | Words. It wraps by default. `fit: .siteName` is the only exception: it shrinks a step, then wraps at the dots. |
| `KeyringButton(KeyringAction)` | A system button: `.advance`, `.approve`, `.deny`, `.plain` or `.link`. On the Watch, `KeyringAction.explain(_:prompt:send:)` opens watchOS's text input. |
| `KeyringStatus` and `KeyringStatusLine` | One line: `.waiting`, `.takingLong`, `.listening`, `.done` or `.problem`, with an optional fixing action. |
| `KeyringConfirmation` | The result card ("You approved it"). |
| `KeyringSteps` and `KeyringStepRow` | Numbered steps: one shared two-column row. |
| `KeyringCopyBlock` | Text to copy, with Copy and then Copied. Not on the Watch. |
| `KeyringQRBlock` and `KeyringQRCode` | A QR code beside its steps. Not on the Watch. |
| `KeyringDeviceRow` and `KeyringRowGroup` | Device rows. Put them in `KeyringRowGroup` on a page, or in a system `List` on the everyday tabs. |
| `KeyringApprovalCard` | The one card for requests, practice and joins. On the Watch its buttons come before the reason. |
| `KeyringReplyBox` | iPhone and Mac reply box: it grows to ten lines, with the microphone button and its state line. |
| `KeyringHint` | A tinted card: Focus, trust, "Not showing up?". |
| `KeyringMascot(mood)` | The keyhole with eyes, in the moods `.calm`, `.curious`, `.waiting`, `.approved`, `.denied` and `.offline`. |
| `KeyringPalette`, `KeyringSpace`, `KeyringRadius`, `KeyringSize` | The tokens from the Paper file's board 5. |

`KeyringGallery.parts` in `Gallery.swift` shows each part in use.

## Adding a page to the checks

Add the page, in each state worth seeing and with the longest words it will hold, to `PageGallery.entries` in `AgentKeyringApprovalUI/PageGallery.swift`:

```swift
.init("first-run-copy-taking-long", .macWindow) {
    MacFirstRunView(screen: .copy(.waitingLong(step: 4)))
},
```

The kinds are `.macWindow`, `.macPanel(width:)`, `.phone` and `.watch`. The test `NothingIsCutOff.everyPageFitsAtTheSmallestSize` then hosts each entry at these sizes:

- Mac: light and dark.
- iPhone: 375 points wide at the default text size, at accessibility size 3, and dark.
- Watch: 41 mm.

It fails on any of these:

- text cut off with an ellipsis;
- a word split across two lines;
- text or a button outside the screen;
- two texts or buttons overlapping;
- text that was laid out but never drawn.

Watch pages must live in a package target to be checked. A view in the Watch app target is out of the tests' reach.

## Running the checks and drawing the pages

Run these from `AgentKeyringPackage`. Given the full path to a folder, each one writes every screen as a PNG, with its words, top to bottom, in a `.txt` file beside it. Use a full path: the simulator does not expand `~`.

```sh
# Mac
KEYRING_RENDER_DIR=/full/path/to/renders/mac swift test --filter AgentKeyringDesignTests
# iPhone, on one simulator, which xcodebuild boots and shuts down
TEST_RUNNER_KEYRING_RENDER_DIR=/full/path/to/renders/iphone \
  xcodebuild test -scheme AgentKeyringDesignChecks -destination 'platform=iOS Simulator,name=iPhone 17e'
# Watch
TEST_RUNNER_KEYRING_RENDER_DIR=/full/path/to/renders/watch \
  xcodebuild test -scheme AgentKeyringDesignChecks -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)'
# Every Mac part and page through the same check, plus the older panel renders
swift run PanelRender /full/path/to/renders/mac
```

The `AgentKeyringDesignChecks` scheme builds only the parts, `AgentKeyringApprovalUI` and these tests, because `AgentKeyringFeature` does not build for iOS. No window opens on screen.

## The copy check

`swift test --filter AgentKeyringCopyTests` reads the copy tables as source: every `*Copy.swift` and `*Words.swift` file, and the Watch app's `WatchCopy`. It fails on:

- an em dash anywhere in the repository, comments included;
- a spaced hyphen used as a dash;
- "relay", "lease", "chip keys" or "always-on Mac";
- an American spelling, from a list in the test.

`KEYRING_COPY_OUT=/path/to/copy.md swift test --filter AgentKeyringCopyTests` writes every string, grouped by table and section, so the whole app reads in one go. Each rendered screen's `.txt` gives the same words in place on that screen.

## What the check cannot see

- **Words handed to native APIs as plain strings.** These include `navigationTitle`, toolbar items, alerts, `Picker` segments, `TextField` placeholders and `Section` headers given as strings. Pass a `KeyringText` where the API takes a view; otherwise keep the words short.
- **Rows of a lazy `List` that are off screen.** They are never laid out, so give the gallery entry a size that shows every row.
- **Apple's own audit as a second layer.** `performAccessibilityAudit(for: .textClipped)` works on iPhone and caught a deliberately cut-off label and button. It needs a UI-test target with an app that shows the pages, which this repository does not have yet. On the Watch it reported nothing, even for a deliberately cut-off label. Apple does not offer it for macOS.
