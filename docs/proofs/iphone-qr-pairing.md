# iPhone QR pairing

Written by AI on 2026.10.12 by model GPT-6 (Codex).

## Verified in this worktree

- `swift test --package-path AgentKeyringPackage`: 239 tests passed
  (183 feature tests in 28 suites, 56 CLI tests in 11 suites).
- The new pairing suite has 7 tests covering 13 cases. It uses the CloudKit
  fake and signed-store signer fake: a valid scanned payload, wrong secret,
  altered public key, altered name, no secret, malformed record, expiry before
  receipt and during comparison, reuse, cancelled comparison, cancelled store
  authentication, canonical wire bytes, and QR validation. Its valid flow also
  exercises the app controller's removal path and device-list refresh.
- macOS Debug, arm64, signing disabled: passed.
- iOS Debug, generic device, unsigned: passed.
- iOS Debug, generic simulator, unsigned: passed.
- Both phone app bundles contain `NSCameraUsageDescription`.

Derived data is under `.build/DerivedData-macOS`, `.build/DerivedData-iOS`, and
`.build/DerivedData-Simulator`. Build/test logs are under `.build/pairing-proof`.
These generated outputs are ignored by Git. The implementation and this record
are committed in this worktree. Nothing was pushed or merged.

## Pair on Josh's devices

1. Build and run **AgentKeyring** from `AgentKeyring.xcodeproj` on the Mac,
   and **AgentKeyringPhone** from `AgentKeyringPhone.xcodeproj` on the physical
   iPhone, using the existing development team and provisioning. These unsigned
   proof builds are not installable device builds. Use the same iCloud account
   and CloudKit environment on both devices.
2. Open the Mac app's main window. If **Add iPhone** is disabled because the
   access rules need confirmation, open **Access Rules…** and confirm those
   rules through the existing authentication prompt first.
3. Click **Add iPhone** on the Mac. Keep the QR sheet open. The code expires
   five minutes after creation; closing the sheet cancels it.
4. On the iPhone, open Agent Keyring and tap **Pair with Mac**. Allow Camera
   access when prompted. Point the camera at the Mac's QR code. Scanning stops
   after the first QR. An unsupported device, denied camera access, or a failed
   upload shows an error instead of claiming success.
5. Wait for **Request sent. Finish pairing on your Mac.** on the iPhone. The
   Mac polls the pairing record every two seconds. Compare the complete
   SHA-256 fingerprint on both screens, and check the device name on the Mac.
   If anything differs, cancel on the Mac and create a fresh code.
6. Before the code expires, click **Add iPhone with Touch ID** on the Mac and
   complete the existing signed-store authentication. The sheet says
   **iPhone added.** and the main window lists the phone. Click **Done**.
7. To revoke it, click **Remove iPhone** beside its name in the same Mac window
   and complete the signed-store authentication. The phone disappears from the
   list and its key is no longer trusted for approval decisions.

The iPhone's name comes from `UIDevice.current.name`; iOS may report the generic
name “iPhone”. Compare the fingerprint even when names match. “Request sent”
only means CloudKit accepted the pairing request. Trust begins after the Mac's
signed-store save.

The QR secret exists only in memory and in the rendered QR. No pairing record
is written by the Mac before scanning. The phone writes `PairingRequest` in
the private `PairingRequests` zone, with ordinary fields `publicKey` (Bytes),
`deviceName` (String), and `authenticationCode` (Bytes), using the pairing UUID
as the record name. It never uploads the secret. The Mac consumes the first
response, verifies its HMAC over the pairing ID, X9.63 key, and verbatim UTF-8
name, and deletes the record before offering confirmation. Rejection,
cancellation, and expiry also end the session and attempt deletion. A CloudKit
deletion failure is reported; it does not enable reuse or establish trust.

Use the development CloudKit environment for the first device proof. If using
production builds, this new record type and its fields must already be deployed
to the production schema. Distribution and schema deployment are outside this
slice.

## Commands

```sh
swift test --package-path AgentKeyringPackage

xcodebuild -project AgentKeyring.xcodeproj -scheme AgentKeyring \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData-macOS CODE_SIGNING_ALLOWED=NO build

xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build

xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData-Simulator CODE_SIGNING_ALLOWED=NO build
```

Physical camera scanning, live CloudKit pairing, Secure Enclave persistence,
and Mac authentication have not been exercised on Josh's devices in this
slice. The builds prove compilation; the fake proves the pairing and removal
logic. The notification service extension remains outside this slice.
