<!-- Written by AI on 2026.11.20 by model claude opus 5.5. -->

# Signing the iPhone and Apple Watch apps

The apps are signed by one person on his own Macs, and by agents working for him. Nothing for signing lives in this repository or on one Mac alone.

## The pieces

- **The App Store Connect API key.** It is used for everything Xcode asks of Apple: development profiles, uploads, and `asc`. It has the App Manager role. The key is kept encrypted in the owner's secrets store, and decrypted for one run only.
- **The team's Apple Distribution certificate.** There is one for the whole team, shared with the owner's other apps. Its private key, as a PKCS#12 file, is kept encrypted in the same secrets store. Each run puts it in a keychain of its own and deletes that keychain afterwards. It never goes into the login keychain.
  - The key cannot use Xcode's cloud-managed distribution certificate ("Cloud signing permission error"), so this certificate is held by the team instead.
- **Development signing.** This is Xcode's automatic signing: Xcode makes and renews the development profiles itself.
- **App Store profiles.** There is one for each of the five targets, kept on App Store Connect. Each is named "Agent Keyring App Store" followed by the part of the bundle identifier after `AgentKeyring.`, for example "Agent Keyring App Store Phone.watchkitapp". Each run fetches them by name and installs them, so no Mac has to be set up beforehand.
  - When the distribution certificate is replaced, make the five profiles again against the new certificate under the same names.

## Building

`script/build_iphone.sh` is the one way to build:

- `script/build_iphone.sh device` makes a Release build signed for development, for installing over a cable.
- `script/build_iphone.sh testflight` makes the App Store build and uploads it to App Store Connect, where TestFlight offers it to internal testers once Apple has processed it. Add `AGENT_KEYRING_UPLOAD=0` to build it without uploading.

The script reads the same variables as `script/build_release.sh`, which builds the Mac app: `AGENT_KEYRING_ASC_KEY_PATH`, `AGENT_KEYRING_ASC_KEY_ID` and `AGENT_KEYRING_ASC_ISSUER_ID`. For `testflight` it also needs `AGENT_KEYRING_DISTRIBUTION_P12` and `AGENT_KEYRING_DISTRIBUTION_P12_PASSWORD`, and `asc` signed in with the same key. The build number is the UTC time unless `AGENT_KEYRING_BUILD_NUMBER` says otherwise, so each upload's number is new.

## Push and export compliance

- **Push environment.** A TestFlight or App Store build carries no provisioning profile, so the app registers production push addresses (`PushEnvironment.isProduction`). A development build reads `aps-environment` from its profile and registers for the sandbox. The relay picks Apple's production or sandbox gateway from each registration.
- **Export compliance.** The app uses encryption: HPKE with AES-GCM, P-256 signatures and key agreement (in the Secure Enclave on devices), SHA-256 and TLS 1.3. All of these are standard algorithms, and the app reaches them only through Apple's frameworks (CryptoKit, Security, Network). Apple treats that use as exempt from export documentation, so `ITSAppUsesNonExemptEncryption` is `NO` in the app's Info.plist.
