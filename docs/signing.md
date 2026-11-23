<!-- Written by AI on 2026.11.20 by model claude opus 5.5; updated on 2026.11.23 by model gemini-4-neon for 0.5.0 public Mac release and external TestFlight status. -->

# Signing the Mac, iPhone and Apple Watch apps

Agent Keyring ships as a signed, notarised Mac app on GitHub Releases (`0.5.0`), alongside an iPhone and Apple Watch companion app currently in internal TestFlight. Nothing for signing lives in this repository.

## Mac app (`script/build_release.sh`)

- **Certificate:** Developer ID Application (`Developer ID Application`, manual export using the Developer ID provisioning profiles for the Mac app and its Credential Provider extension).
- **Notarisation:** `script/build_release.sh` builds the universal (`arm64` + `amd64`) `agent-keyring` helper binary, archives and exports `Agent Keyring.app`, notarises `Agent-Keyring-<VERSION>.zip` with `xcrun notarytool submit --wait` using an App Store Connect API key, staples the ticket, and verifies `codesign`, `stapler`, and `spctl`.
- **Publishing:** `script/publish_release.sh <VERSION>` creates the GitHub Release on `opentrawl/agent-keyring` from `.build/Release-<VERSION>/out/Agent-Keyring-<VERSION>.zip` and `Distribution/ReleaseNotes.md`.

## iPhone and Apple Watch apps (`script/build_iphone.sh`)

### The pieces

- **The App Store Connect API key.** Used for profiles, uploads and `asc` (`AGENT_KEYRING_ASC_KEY_PATH`, `AGENT_KEYRING_ASC_KEY_ID`, `AGENT_KEYRING_ASC_ISSUER_ID`). Kept encrypted in the maintainer's secrets store and decrypted into a mode-700 temp directory for one run only.
- **The team's Apple Distribution certificate.** Held as a PKCS#12 file (`AGENT_KEYRING_DISTRIBUTION_P12`, `AGENT_KEYRING_DISTRIBUTION_P12_PASSWORD`), imported into a temporary keychain for the build and deleted afterwards.
- **App Store profiles.** Five profiles on App Store Connect, named `"Agent Keyring App Store <suffix>"` for `Phone`, `Phone.NotificationService`, `Phone.NotificationContent`, `Phone.watchkitapp` and `Phone.watchkitapp.NotificationService`, fetched by name each run.

### Building

- `script/build_iphone.sh device` builds a Release app signed for development over USB.
- `script/build_iphone.sh testflight` archives, exports and uploads to App Store Connect for internal TestFlight. Set `AGENT_KEYRING_UPLOAD=0` to export locally without uploading.

The version and build number come from `script/version.sh` (`VERSION` file + commit UTC timestamp `YYYYMMDDHHMM`), so the Mac app, iPhone/Watch app and CLI share the same pair.

### Push delivery and external TestFlight

- **Internal builds (today):** The Mac app and enrolled computers send Apple Push Notification Service (APNs) alerts directly to Apple using the team's private APNs `.p8` key installed via `agent-keyring push-key`.
- **External TestFlight (next):** External testers cannot be given the team's private APNs `.p8` key, so public TestFlight waits on a small stateless push-forwarding service holding the team key that relays already end-to-end-encrypted opaque push payloads to Apple (and an external TestFlight group passing Beta App Review).
- **Export compliance:** Standard Apple framework cryptography only (CryptoKit HPKE/AES-GCM, Secure Enclave P-256, SHA-256, TLS 1.3), declared exempt via `ITSAppUsesNonExemptEncryption = NO`.
