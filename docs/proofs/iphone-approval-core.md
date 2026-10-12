# iPhone approval core validation

Written by AI on 2026.10.12 by model GPT-6 (Codex).

The approval records, canonical encoding and CloudKit mapping live in
`AgentKeyringApprovalCore`, shared by the Mac feature and iPhone app. The app
creates a persistent Secure Enclave key, registers the three notification
actions, fetches full encrypted request records, signs the canonical bytes,
and uploads decisions. Pairing and the notification service extension remain
outside this slice.

## Tests

`swift test --package-path AgentKeyringPackage --scratch-path .build/package-tests`
passed: **176 feature tests in 27 suites + 56 CLI tests in 11 suites = 232 tests**.
The original 227 tests remain passing.

The five new parity tests execute **27 cases**: six valid choice/action
combinations, seven mutated request fields, two mutated choices, one changed
request ID, and eleven malformed records. They use the shared CloudKit mapping
and canonical encoding with a CryptoKit P-256 key standing in for the phone's
Secure Enclave, and the real Mac verifier with its signed paired-device store.

After strengthening the malformed-record cases to keep all other valid fields,
`swift test --package-path AgentKeyringPackage --scratch-path .build/package-tests
--filter PhoneApprovalParityTests` also passed all five tests and 27 cases.

## Builds

Xcode 27.0, build 27A5194q. All three commands exited 0 with `BUILD SUCCEEDED`:

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
```

The build CLI was unavailable, so validation used `xcodebuild` directly.
Build warnings were limited to App Intents metadata extraction with no
AppIntents dependency, and skipping stripping of pre-signed Sparkle artifacts.
Logs from this run are in the worktree's ignored `.build/validation/` directory.

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
4. After the later pairing slice establishes trust, lock the Mac and verify
   that a waiting agent request completes from the phone, replay is refused,
   and an expired notification releases nothing. Confirm Deny and Block reach
   the Mac with their intended behavior.

No device installation, signed run, live CloudKit access, model review, push
or merge was performed. The app currently uses generic visible alerts; private
notification text and time-sensitive delivery require the later service extension.
