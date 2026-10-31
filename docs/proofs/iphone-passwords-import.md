Written by AI on 2026.10.31 by model gpt-6.1-sol.

# iPhone Passwords import: R4.1

R4.1 registers Agent Keyring as a credential exchange destination and receives
Apple's export in the containing iPhone app. The Mac and phone use the same
mapper, import types and additive merger from `AgentKeyringCredentialImport`.
The Mac feature module re-exports them, so its callers do not change.

## Boundary for R4.2

`PhoneImportBackend` handles `ASCredentialExchangeActivity`, redeems each token
once, maps with `.unknown` scope, and calls
`PhoneCredentialImportDestination.receive(_:)`. The batch contains passwords
and code seeds; it must never go into chat, diagnostics or an unencrypted file.

R4.1's `ReceiptOnlyPhoneImportDestination` returns `.receivedOnly`. It does not
retain the batch. The phone shows the received and skipped counts and explicitly
says the logins were **not saved**. Only that receipt is written to Application
Support, as `last-import-receipt.plist`; it survives closing the app. The current
screen protocol has no receipt-only state, so this is presented through
`.importFailed(message)`, never through `.imported`.

R4.2 replaces this destination with a vault that seals and additively merges the
batch before returning `.saved(totalLoginCount:at:)`, and initializes the backend
from that vault's durable state. It must preserve existing logins for unknown or
selected exports. Receipt-only mode does not establish refresh or vault behavior.
Do not build an intermediate plaintext store. Phone IDs and relay publishing
remain R4.2 work.

The designer's views are unchanged. Normal launch uses the real import backend;
explicit `-designScenario` launches still use the gallery mocks. The old
CloudKit approval preparation is no longer started by normal launch: this slice
does not set up the old biometric-free signing key or ask for push permission.
Relay approvals arrive in R4.3.

## Verified on 31 October

- Xcode 27 beta builds the containing app and both embedded extensions for
  iPhoneOS, minimum deployment iOS 26.
- The generic iOS Simulator build succeeds on the Mac mini using
  `/Applications/Xcode-beta.app`. The shared Mac feature package builds there.
- The device bundle passes `codesign --verify --deep --strict`. The host and
  credential extension have AutoFill Credential Provider entitlements, and the
  extension advertises credential exchange version `1.0`.
- Automatic signing uses the existing Apple Development certificate. No
  certificate was created, deleted or revoked. Xcode registered the new
  extension identifier and updated development profiles for the actual iPhone.
- Agent Keyring **0.4.0 (4)** is installed on the paired iPhone running iOS 27.
  Installation was checked through CoreDevice's installed-app inventory.
- Foreground launch was refused because the iPhone is locked. No phone settings
  were changed and no real credential exchange was attempted.

No simulator run is claimed: the mini's SSH user has no simulator runtime. A
runtime download was stopped; the simulator SDK build above is compile evidence
only. The MacBook's simulator was not booted and no simulator window was opened.

## Morning device check

1. Unlock the iPhone and open **Agent Keyring**.
2. Tap **Open Passwords** and allow Agent Keyring as a credential provider if
   iOS asks. This button currently performs provider enablement. iOS exposes no
   public Passwords export deep link; switch to **Passwords** yourself. The
   button label belongs to the designer's follow-up.
3. In Passwords, choose **… → Export Data to Another App**. Select **one test
   login**, choose **Agent Keyring**, and authenticate when Apple asks.
4. Confirm Agent Keyring opens and reports the expected received password and
   code counts, with the skipped counts. On this R4.1 build it must say the
   logins were **not saved**. Close and reopen it: the same receipt remains.
5. If Agent Keyring is absent, check **Settings → General → AutoFill &
   Passwords** and enable it, then try the selected export again. Report that
   failure rather than calling registration proved.

The done condition remains **unproved until this Apple-controlled hand-off
passes on the real phone**. Re-exporting a changed password without losing
other logins is the next slice's device check, after encrypted storage exists.

## Diagnostics

Capture the iPhone in macOS Console with this subsystem and category:

```text
subsystem: com.joshpalmer.AgentKeyring.Phone
category: Import
```

Stages are activity received, token present (or duplicate/missing), import
started, Apple import completed (or error), mapped counts, destination
completed, and receipt saved (or error). Errors log only domain/code chains,
never localized descriptions, `userInfo`, tokens, accounts, sites or secrets.
Start capture before exporting. If there is no activity-received line, the
failure happened before the app's import handler. If Apple rejects the token,
start a fresh export; the token cannot be replayed as a diagnostic.

Apple's contracts:
[credential exchange import](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager),
[host and extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.authentication-services.autofill-credential-provider),
[SwiftUI activity handling](https://developer.apple.com/documentation/swiftui/environmentvalues/credentialimportmanager),
[provider enablement](https://developer.apple.com/documentation/authenticationservices/assettingshelper/requesttoturnoncredentialproviderextension(completionhandler:)).
