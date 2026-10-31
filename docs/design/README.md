---
written_by: ai (Claude Opus 5.5, 2026-10-31), from Josh's steering of 12 Oct and 30 Oct
---

# Agent Keyring design

Two notes, one per app:

- [iPhone](iphone.md): answer requests away from the Mac, and hold the passwords.
- [Mac](mac.md): answer requests at the keyboard with Touch ID, see what agents are using, set rules.

Screenshots of every state are in [screens/](screens/), rendered from the real SwiftUI views with mock data.

## The language

Swiss and plain. Type and space carry the hierarchy, not boxes.

- **Type.** SF Pro at Dynamic Type sizes, left-aligned. On a request the site is the largest thing on screen, because it is what you are deciding about.
- **Colour.** Three colours, each with one meaning, and nothing pastel:
  - Green `#1A7F37`: approve, and logins agents may use.
  - Red `#CF222E`: deny, block, end.
  - Blue `#0A4BD6`: Agent Keyring itself, so waiting, timers and links.
- **Structure.** Hairlines between groups, no cards. Facts are a two-column list, labels on the left.
- **Facts and claims are kept apart.** What Agent Keyring saw (the login, the machine and its address, the access) is a plain list. What came from the agent (its name, its reason and the folder it says it's in) sits under "Codex says", with "From the agent. Agent Keyring can't check it." RFC 0007 lists the source of every item.
- **Normal interactions only.** Two buttons, Face ID or Touch ID. No hold-to-approve, no swipes to approve.

## Changing things

All of it lives in `AgentKeyringPackage/Sources/AgentKeyringApprovalUI`:

| To change | Edit |
| --- | --- |
| Any sentence | `Shared/AccessRequestCopy.swift` (rule names: `Shared/LoginRule.swift`) |
| Colours, button shape, spacing | `Shared/KeyringStyle.swift` |
| What a request carries | `Shared/AccessRequest.swift` |
| The question, facts and claim block (both apps) | `Shared/AccessRequestParts.swift` |
| Mock data | `Shared/DesignExamples.swift`, `Phone/PhoneDesignScenario.swift`, `Mac/MacDesignGallery.swift` |

Views only read view models (`PhoneKeyringModel`, `MacApprovalModel`, `MacMenuBarModel`, `MacRulesModel`). Each model talks to the outside world through one protocol (`PhoneKeyringBackend`, `MacApprovalBackend`, `MacMenuBarBackend`, `LoginRulesBackend`): a stream of updates plus one call per thing Josh can do. Today those are mocks; the real backends replace them without touching a view. RFC 0007 maps each lease state and purpose to what the screens show.

To refresh the screenshots:

- iPhone: `script/capture_phone_design_screens.sh` (headless simulator).
- Mac: `script/capture_mac_design_screens.sh` (runs on the Mac mini over Screen Sharing, so nothing appears on this Mac).
