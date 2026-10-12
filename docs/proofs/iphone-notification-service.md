# iPhone approval notification service

Written by AI on 2026.10.12 by model GPT-6 (Codex).

## Verified in this worktree

- iOS generic device Debug build: passed, signing disabled.
- iOS generic simulator Debug build: passed, signing disabled.
- macOS arm64 Debug build: passed, signing disabled; macOS sources and project unchanged.
- Both iOS app bundles contain the notification service extension, with the
  correct notification service entry point and bundle identifier.
- The extension declares only the same iCloud container and CloudKit service
  entitlements as the phone app. It has no push, keychain or app-group entitlement.
- `swift test --package-path AgentKeyringPackage`: 241 tests passed across
  40 suites (183 feature, 56 CLI, 2 shared-core tests).
- The new shared-core tests cover six field/action combinations against fixed
  canonical byte vectors, ignore stale notification templates, and reject a
  missing encrypted site even when plaintext site exists.
- The focused notification, phone/Mac signature parity and CloudKit channel
  suites passed before the full test run.

Xcode emitted App Intents metadata notices because these targets do not use
App Intents. The Mac build also retained already signed Sparkle vendor binaries
without stripping them. No compilation errors occurred.

## Commands

Run from the worktree root:

```sh
xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/.build/DerivedData-iOS" CODE_SIGNING_ALLOWED=NO build

xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/.build/DerivedData-Simulator" CODE_SIGNING_ALLOWED=NO build

xcodebuild -workspace AgentKeyring.xcworkspace -scheme AgentKeyring \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/.build/DerivedData-macOS" CODE_SIGNING_ALLOWED=NO build

swift test --package-path AgentKeyringPackage
```

The build CLI was unavailable; Xcode and Swift needed access beyond the sandbox
to use their normal caches. All derived data and package build output stayed
in the worktree.

## Josh's device checks

Use a signed installation on the paired iPhone, with the extension's profile
allowing the same CloudKit container and environment as the app and Mac.
Open the phone app once so it saves the current mutable-content subscription.
Enable notification previews and Time Sensitive Notifications for this check.

1. With the phone locked and the Mac locked or sleeping, request a login from
   an agent. Confirm the notification shows the actual agent and field in the
   title, site and account in the body, and `fill` or `acquire` in the subtitle.
   Repeat for the other action and a different field.
2. Confirm it appears as time-sensitive, including through a Focus that allows
   time-sensitive alerts. Confirm only one alert appears for each request.
3. Expand the notification and approve. Confirm Face ID/device authentication
   is the only presence check, and the waiting Mac operation completes. Repeat
   Deny and Block this login; neither should release a credential.
4. Exercise a record-fetch failure and a fetch held beyond the service
   extension deadline (for example, stop connectivity after push delivery or
   pause the fetch in an attached extension debugger). Confirm the body is
   `An agent is asking for a login. Open to review.`, the title is `Login approval`,
   and the subtitle is empty, with no invented or stale login details.
5. Act on a notification after its request has expired or been deleted.
   Confirm no decision authorizes a credential release. A fetch failure while
   handling an action must also send no signed decision.

Physical push delivery, encrypted CloudKit access from the signed extension,
time-sensitive presentation, fallback at the system deadline, and one-tap
Secure Enclave approval remain unverified until these checks run on the phone.
No device installation, model review, push or merge was performed in this slice.
