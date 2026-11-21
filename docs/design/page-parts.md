---
written_by: ai (Claude Opus 5.5, 2026-11-21), for the engineers building the pages
---

# Building a page from the parts

Every first-run page, device flow and everyday screen is built from the parts in `AgentKeyringPackage/Sources/AgentKeyringDesign`, and from nothing else. The parts own every margin, gap, colour and type size, so a page cannot come out cropped or hand-made. A check hosts each page at the smallest size each device gives it and fails if any text or button is cut off.

## The rules

1. Every word on screen goes through `KeyringText`. Button labels already do, because `KeyringButton` uses it. A plain `Text`, a raw colour, a padding or a fixed `.frame(height:)` on a page goes round the check.
2. Never clip around text: no `.clipped()`, no clip shape, no fixed height. The window is the only clip, and the check watches it.
3. Blue (`.advance`) moves setup on. Green (`.approve`, `.approveLink`) and red (`.deny`, `.denyLink`) only ever approve or deny. Everything else is `.plain` (grey) or `.link` (blue text).
4. Words come from the copy tables (`SetupCopy`, `PhoneCopy` and the rest). The parts' own words are in `PartsCopy`.

## The parts

| Part | What it is |
| --- | --- |
| `KeyringSetupWindow(heading:steps:mascot:) { page }` | Mac setup window, 760 by 560: step list and mascot on the left, the page on the right. |
| `KeyringPage(step:title:sentence:alignment:mascot:status:primary:secondary:aside:) { body }` | One page. Mac: the buttons sit along the bottom. iPhone: it scrolls, with the buttons pinned at the bottom. Watch: one scrolling column. |
| `KeyringText(words, as: role, fit:)` | Words. It wraps by default. `fit: .siteName` is the only exception: it shrinks a step, then wraps at the dots. |
| `KeyringButton(KeyringAction)` | A system button: `.advance`, `.approve`, `.deny` or `.plain`; or words alone: `.link`, `.approveLink` (Approve Instead) or `.denyLink` (Deny and Explain). On the Watch, `KeyringAction.explain(_:prompt:send:)` opens watchOS's text input. |
| `KeyringStatus` and `KeyringStatusLine` | One line: `.waiting`, `.takingLong`, `.listening`, `.done` or `.problem`, with an optional fixing action. |
| `KeyringConfirmation` | The result card ("You approved it"). |
| `KeyringSteps` and `KeyringStepRow` | Numbered steps: one shared two-column row. |
| `KeyringCopyBlock` | Text to copy, with Copy and then Copied. Not on the Watch. |
| `KeyringQRBlock` and `KeyringQRCode` | A QR code beside its steps. Not on the Watch. |
| `KeyringCheckRow(title, isDone:, toDo:)` | A checklist line: a green tick when done, else an orange mark and what to do. |
| `KeyringDeviceRow` and `KeyringRowGroup` | Device rows. Put them in `KeyringRowGroup` on a page, or in a system `List` on the everyday tabs. |
| `KeyringApprovalCard` | The one card for requests, practice and joins. On the Watch its buttons come before the reason. |
| `KeyringRequestHeader` | The card's top on its own: who asks, the site, the account and the reason, centred. Use it as the body of a page about one request; `KeyringPage`'s title is optional for this. |
| `KeyringReplyBox` | iPhone and Mac reply box: it grows to ten lines, with the microphone button and its state line. |
| `KeyringHint` | A tinted card: Focus, trust, "Not showing up?". |
| `KeyringMascot(mood)` | The keyhole with eyes, in the moods `.calm`, `.curious`, `.waiting`, `.approved`, `.denied` and `.offline`. |
| `KeyringPalette`, `KeyringSpace`, `KeyringRadius`, `KeyringSize` | The tokens from the Paper file's board 5. |

`KeyringGallery.parts` in `Gallery.swift` shows each part in use.

## Adding a page to the checks

Add the page, in each state worth seeing and with the longest words it will hold, to `PageGallery.entries` in `AgentKeyringApprovalUI/PageGallery.swift`:

```swift
// Illustrative: use the page's real state.
.init("first-run-copy-taking-long", .macWindow) {
    MyCopyPasswordsPage(state: .waitingLong(step: 4))
},
```

The kinds are `.macWindow`, `.macPanel(width:)`, `.phone` and `.watch`. The test `NothingIsCutOff.everyPageFitsAtTheSmallestSize` then hosts each entry at these sizes:

- Mac: light and dark.
- iPhone: 375 points wide at the default text size, at accessibility size 3, and dark.
- Watch: 41 mm.

It fails on any of these:

- text cut off with an ellipsis;
- a word split across two lines;
- a button label on more than one line, unless the button takes the whole width (a button sharing its row should move under the words, as `KeyringDeviceRow` does);
- text or a button outside the screen;
- two texts or buttons overlapping;
- text that was laid out but never drawn.

Scrolling screens (iPhone and Watch) are drawn as long as their content, again and again if need be, so a system `List` is checked to its last row and nothing below the fold counts as cut off. Watch pages must live in a package target to be checked. A view in the Watch app target is out of the tests' reach.

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

When the simulator runs short of memory, set `KEYRING_GALLERY_PART=1/4` (then 2/4, 3/4 and 4/4; with xcodebuild, `TEST_RUNNER_KEYRING_GALLERY_PART`) to check every fourth entry per run.

The `AgentKeyringDesignChecks` scheme builds only the parts, `AgentKeyringApprovalUI` and these tests, because `AgentKeyringFeature` does not build for iOS. No window opens on screen. The Watch run also boots the iPhone simulator paired with it and leaves it running: shut it down with `xcrun simctl shutdown <its id>` when done.

## The copy check

`swift test --filter AgentKeyringCopyTests` reads the copy tables as source: every `*Copy.swift` and `*Words.swift` file, and the Watch app's `WatchCopy`. It fails on:

- an em dash anywhere in the repository, comments included;
- a spaced hyphen used as a dash;
- "relay", "lease", "chip keys" or "always-on Mac";
- an American spelling, from a list in the test.

`KEYRING_COPY_OUT=/path/to/copy.md swift test --filter AgentKeyringCopyTests` writes every string, grouped by table and section, so the whole app reads in one go. Each rendered screen's `.txt` gives the same words in place on that screen.

## What the pictures do not show

The checks are right about where every text and button sits, and the words in the `.txt` files are exact. But each picture is taken a different way on each device, and some system controls look wrong in it:

- **iPhone.** A package test has no app and so no window scene, so the screen is drawn with `layer.render(in:)`. That does not draw iOS's glass and blur materials. Tab bars, toolbar buttons, search fields and anything else made of Liquid Glass come out as white shapes, often with white icons and text on a pale ground. Proven side by side in a scratch app: the same screen drawn with `drawHierarchy` in a real scene shows them correctly. Trust their place in the picture, not their look.
- **Watch.** SwiftUI's `ImageRenderer` cannot draw some system controls. A `ProgressView`, for example, appears as a yellow box with a crossed circle, at its real size.
- **Mac.** The window is drawn with `cacheDisplay`. Buttons and lists look as macOS draws them, but always as in a window that is not in front.

## What the check cannot see

- **Words handed to native APIs as plain strings.** These include `navigationTitle`, toolbar items, alerts, `Picker` segments and `Section` headers given as strings. (The reply boxes draw their own prompts for this reason: a text field's placeholder was cut off at large text and the check could not see it.) Pass a `KeyringText` where the API takes a view; otherwise keep the words short.
- **Apple's own audit as a second layer.** `performAccessibilityAudit(for: .textClipped)` works on iPhone and caught a deliberately cut-off label and button. It needs a UI-test target with an app that shows the pages, which this repository does not have yet. On the Watch it could not be tried: the test runner failed to launch the app, and the audit then saw nothing at all. Apple does not offer it for macOS.
