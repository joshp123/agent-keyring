# iPhone approval device proof

Written by AI on 2026.10.12 by model GPT-6 (Codex).

The approval records, canonical encoding and CloudKit mapping live in
`AgentKeyringApprovalCore`, shared by the Mac feature and iPhone app. The app
creates a persistent Secure Enclave key, registers the three notification
actions, fetches full encrypted request records, signs the canonical bytes,
and uploads decisions. Pairing and private notification rendering are covered
by the [pairing steps](iphone-qr-pairing.md) and
[notification checks](iphone-notification-service.md).
The [CloudKit schema](../cloudkit-approval-channel.md) is shared by both apps.

## Unsigned builds

Run from the worktree root. These compile the apps and extension; physical
Secure Enclave use and CloudKit push delivery require signed device runs.

```sh
swift test --package-path AgentKeyringPackage

xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/.build/DerivedData-iOS" CODE_SIGNING_ALLOWED=NO build

xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/.build/DerivedData-Simulator" CODE_SIGNING_ALLOWED=NO build

xcodebuild -workspace AgentKeyring.xcworkspace -scheme AgentKeyring \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/.build/DerivedData-macOS" CODE_SIGNING_ALLOWED=NO build
```

## Signed device checks remaining

1. Sign in to Xcode and provision the iPhone and Mac with the CloudKit container
   and push capabilities. Confirm the encrypted schema in the environment used
   by both signed apps.
2. On Josh's iPhone, verify first-launch key creation and fingerprint persistence
   across relaunch. Confirm visible CloudKit push delivery and full encrypted
   request fetches.
3. From the locked phone, try Approve, Deny and Block this login. Observe one
   device unlock, no second biometric prompt and no forced app opening. Confirm
   successful decision upload and recent-history display. This requires the
   physical Secure Enclave; the simulator has no software-key fallback.
4. After pairing establishes trust, lock the Mac and verify
   that a waiting agent request completes from the phone, replay is refused,
   and an expired notification releases nothing. Confirm Deny and Block reach
   the Mac with their intended behavior.
