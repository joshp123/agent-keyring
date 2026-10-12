# iPhone notification signing spike

Written by AI on 2026-10-12 by model GPT-6 (Codex).

This standalone project tests RFC 0002 section 4 on a physical iPhone. It does
not depend on or change the Mac app or Swift package.

The persistent P-256 key is created in the Secure Enclave with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `.privateKeyUsage` only.
Approve has `.authenticationRequired`, without `.foreground`. It signs the
fixed UTF-8 payload `AgentKeyringPhone signing spike fixed payload v1` using
ECDSA with SHA-256. Deny records the action without signing.

## Current evidence

The unsigned physical-iOS build succeeded with Xcode 27. This verifies
compilation only; it cannot be installed and does not prove device behavior.

The signed build stopped at provisioning: Xcode reports **No Accounts** and
**No profiles for 'com.joshpalmer.AgentKeyring.Phone' were found**. Josh must
add the Apple developer account for team `7M8BR7R488` in Xcode → Settings →
Accounts. No installation or launch was attempted. No physical signing result,
biometric-prompt observation, or latency measurement exists yet.

`Config/Local.xcconfig` is absent in this worktree. The separate iOS project
uses the bundle ID and team supplied for this slice, with automatic signing.

## Build, install, launch

Run from this worktree after the account is available:

```sh
xcodebuild -project AgentKeyringPhone.xcodeproj \
  -scheme AgentKeyringPhone -configuration Debug \
  -destination 'id=00008150-00054D9E3E08401C' \
  -allowProvisioningUpdates -derivedDataPath .build/iphone-signing build

xcrun devicectl device install app \
  --device D64C0D7C-1ED8-5C6D-8B04-2952ECFD2454 \
  .build/iphone-signing/Build/Products/Debug-iphoneos/AgentKeyringPhone.app

xcrun devicectl device process launch \
  --device D64C0D7C-1ED8-5C6D-8B04-2952ECFD2454 \
  com.joshpalmer.AgentKeyring.Phone
```

Stop if provisioning or the phone requires Josh's intervention.

## Physical test

1. Allow notifications on first launch. Confirm `KEY_READY … success` appears.
2. Tap **Send test request**, then lock the phone within 15 seconds.
3. Expand the lock-screen notification and tap **Approve**. Let Face ID unlock
   the device. Observe whether another biometric prompt appears and whether
   the app opens. These observations must come from Josh; the log cannot prove
   the number of prompts.
4. Open the app to read the log, or copy it using the command below. Repeat to
   collect first and subsequent signing times. Optionally test Deny separately.

Each action line includes UTC ISO time, action, application state, success or
failure with error domain/code, and milliseconds. Duration starts at entry to
the notification response handler and ends after key lookup and signing,
before disk logging. It includes dispatch to the main actor but excludes the
system's preceding unlock and Face ID duration. A successful Approve line also
records signature length. Setup and scheduling events are logged separately.
The log can be written after the phone has first been unlocked, including for
Deny while locked. The key itself still requires an unlocked device.

## Copy the log

```sh
xcrun devicectl device copy from \
  --device D64C0D7C-1ED8-5C6D-8B04-2952ECFD2454 \
  --domain-type appDataContainer \
  --domain-identifier com.joshpalmer.AgentKeyring.Phone \
  --source Documents/signing-spike.log \
  --destination /Users/josh/code/agent-keyring-worktrees/spike-iphone-signing/.build/iphone-signing/signing-spike.log
```

The copy syntax was checked against local `devicectl` help. It has not been
executed because the app is not installed.
