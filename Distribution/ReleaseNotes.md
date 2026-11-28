---
written_by: AI on 2026.11.23 by model gemini-4-neon for the v1.0.0 release; 1.1.0 by model claude opus 5.5 and gemini-4-neon on 2026.11.24
---

**1Password for the Agentic OS.** Let your AI agents sign in as you anywhere you work, using the passwords you already keep in Apple Passwords, approved with Touch ID on your Mac or Face ID on your iPhone and Apple Watch.

### What is new in 1.1.0

- **No Tailscale, and no network to set up.** Everything travels three ways: your own iCloud private database between your Macs and iPhones; Apple's push service, to wake a device; and a zero-data-retention relay of end-to-end encrypted boxes (`push.opentrawl.sh`, or your own `agent-keyring-box`) between your devices and an agent computer. The relay sees only random box IDs, kept out of URLs, and ciphertext; it is run with no per-request logs, deletes a join, answer or update box when it is picked up, stops serving unread boxes when their time runs out, and lets AWS remove expired rows from DynamoDB (usually within a few days). It can drop or delay a message but cannot read or forge one.
- **Add a computer with a one-time code.** `agent-keyring enrol --name NAME --code CODE`, with a code from Add Another Computer on your Mac or iPhone. A self-hosted relay comes in the code's link (`agentkeyring://join?code=...&relay=...`) and must be served over HTTPS with a certificate your iPhone and Apple Watch trust.
- **Your iPhone works on its own.** Set Up on This iPhone, export from Apple Passwords on the iPhone, add your Apple Watch and add agent computers, with no Mac at all. Every Mac and iPhone is an equal and keeps the others up to date through your iCloud; a new Mac can join a list that started on an iPhone.
- **Apple Watch keeps its own copies.** Each password is sealed to the Watch's Secure Enclave and sent to the Watch by your iPhone directly. Copies your Mac seals for it pass through your iCloud as ciphertext only the Watch can open. None goes to a computer or the relay.
- **Stop works from anywhere, at any time.** Every approval has a grant at the relay that Stop on your Mac, iPhone or Apple Watch marks stopped, and the computer checks it before every use: an approval whose grant cannot be checked is not used. Stop on your Mac now ends another computer's approval too, for its whole 30 minutes.
- **Computers keep up by themselves.** Each computer has an update mailbox that your Mac and iPhone write after every change and once a day, so a rule change or a removed device reaches it with no Mac awake. A computer uses its Automatic passwords on its own only while it has heard from your devices in the last week.
- **Practice requests between your Mac, iPhone and Apple Watch**, through the same relay, with no Mac needed for the iPhone and Apple Watch.
- **App Transport Security is back on.** The Mac, iPhone and Apple Watch apps and their notification extensions no longer turn it off.
- **Sparkle 2 automatic updates:** The Mac app checks `https://keyring.opentrawl.sh/appcast.xml`, verifies every update with its Ed25519 signing key, and installs updates automatically (with a manual Check for Updates… action in the app menu and menu bar popover).

### Upgrading

- Users on 1.0.1 receive 1.1.0 automatically through Sparkle; users on 1.0.0 need to install once from GitHub Releases.
- Update `agent-keyring` on every computer. An older command still asks for answers at a Tailscale door, which the 1.1 apps no longer answer.
- A computer that joined over Tailscale must join again: run `agent-keyring enrol --name NAME --code CODE` there with a new code. Its old enrolment is refused with that instruction.
- `agent-keyring machines`, `enrol --invite` and `agent-keyring hold` are gone, with everything else that used Tailscale. `agent-keyring complain` keeps a complaint on the computer it ran on, and `agent-keyring logs` shows that computer's own log.

### Also in this release

- **Blind APNs push forwarder for iPhone and Apple Watch (`push.opentrawl.sh`):** iPhone and Apple Watch push approvals work out of the box without your own Apple Developer `.p8` key. The stateless forwarder in AWS `eu-west-1` sees only already-encrypted push blobs and device tokens, never passwords, sites, or approvals. Self-builders with their own Apple Developer key can still push directly to Apple with `agent-keyring push-key`.
- **Standalone Linux and macOS CLI binaries:** `agent-keyring-linux-amd64`, `agent-keyring-linux-arm64`, `agent-keyring-darwin-universal` and `SHA256SUMS.txt` beside the Mac app, so remote servers need no Nix.
- **Zero-PII daily version check:** at most once a day, with the version, platform, architecture and one stable, anonymous, non-reversible hash (no IP stored, no sites or passwords). Turn it off in Devices on the Mac or Settings on the iPhone, with `no_telemetry`, or with `AGENT_KEYRING_NO_TELEMETRY=1`.

### Site and iPhone and Apple Watch beta

- Website and docs: [keyring.opentrawl.sh](https://keyring.opentrawl.sh/)
- iPhone and Apple Watch public beta: [TestFlight](https://testflight.apple.com/join/W5xBNeMw)
