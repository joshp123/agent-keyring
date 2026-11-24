<!-- Written by AI on 2026.11.20 by model claude opus 5.5; updated on 2026.11.24 by model gemini-4-neon for Sparkle 2 automatic updates and signed appcast publishing. -->

# Signing the Mac, iPhone and Apple Watch apps

Agent Keyring ships as a signed, notarised Mac app on GitHub Releases with Sparkle 2 automatic updates (`https://keyring.opentrawl.sh/appcast.xml`), alongside an iPhone and Apple Watch companion app in public TestFlight. Nothing for signing lives in this repository.

## Mac app (`script/build_release.sh`)

- **Certificate:** Developer ID Application (`Developer ID Application`, manual export using the Developer ID provisioning profiles for the Mac app and its Credential Provider extension).
- **Notarisation:** `script/build_release.sh` builds the universal (`arm64` + `amd64`) `agent-keyring` helper binary, archives and exports `Agent Keyring.app`, notarises `Agent-Keyring-<VERSION>.zip` with `xcrun notarytool submit --wait` using an App Store Connect API key, staples the ticket, and verifies `codesign`, `stapler`, and `spctl`.
- **Sparkle 2 appcast:** `script/build_release.sh` checks that `SUPublicEDKey` in `AgentKeyring/Info.plist` matches the maintainer's Ed25519 key in the login Keychain (`script/fetch_sparkle_tools.sh`), checks that the build number is newer than the live feed, generates `.build/Release-<VERSION>/out/appcast.xml` pointing at `https://github.com/opentrawl/agent-keyring/releases/download/v<VERSION>/Agent-Keyring-<VERSION>.zip`, and verifies the Ed25519 signature against the zip bytes.
- **Publishing:** `script/publish_release.sh <VERSION>` creates (or resumes) the GitHub Release on `opentrawl/agent-keyring` from `.build/Release-<VERSION>/out/Agent-Keyring-<VERSION>.zip`, the standalone CLI binaries, `SHA256SUMS.txt`, and `Distribution/ReleaseNotes.md`, confirms the release zip is live over HTTPS, conditionally uploads `appcast.xml` to the configured S3 bucket (`AGENT_KEYRING_APPCAST_BUCKET`, `Cache-Control: public, max-age=300`) using its ETag, invalidates `/appcast.xml` in CloudFront (`AGENT_KEYRING_CLOUDFRONT_DISTRIBUTION_ID`), and verifies `https://keyring.opentrawl.sh/appcast.xml` byte-for-byte.

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
