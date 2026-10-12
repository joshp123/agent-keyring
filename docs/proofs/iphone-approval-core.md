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

Both apps and the notification extension must use the same CloudKit
environment. On a fresh Development schema, the Mac must save an approval
request before the phone saves its query subscription: the record type does
not exist until that first save. After deploying the schema, pin
`com.apple.developer.icloud-container-environment` to `Production` in both
apps and the extension, and use signed profiles for that environment.

1. Provision the iPhone, Mac and notification extension with the CloudKit
   container and push capabilities. Use the same iCloud account and environment.
2. Pair the phone using the [QR steps](iphone-qr-pairing.md), then close the
   phone app. On a fresh Development schema its automatic subscription attempt
   during pairing may fail because `ApprovalRequest` does not exist yet;
   this does not prevent pairing.
3. With the paired phone app closed, lock the Mac and send an agent login
   request. Wait until the Mac saves it to CloudKit; this creates
   `ApprovalRequest` on a fresh schema. Then relaunch the phone app so it saves
   its query subscription against the existing record type. Verify Secure
   Enclave key and fingerprint persistence across relaunch. The setup request
   is not part of the notification delivery proof.
4. Send a new request. Confirm visible CloudKit push delivery and full encrypted
   request fetches. From the locked phone, try Approve, Deny and Block this login.
   Observe one device unlock, no second biometric prompt and no forced app
   opening. Confirm successful decision upload and recent-history display.
   This requires the physical Secure Enclave; the simulator has no software-key
   fallback.
5. Lock the Mac and verify a waiting agent request completes from the phone,
   replay is refused, and an expired notification releases nothing. Confirm
   Deny and Block reach the Mac with their intended behavior. Restart the Mac
   app after a phone block and confirm it stays blocked until the next signed
   access-rules save.
