---
written_by: AI on 2026.11.24 by model gemini-4-neon for the v1.0.1 release
---

**Automatic updates for the Mac app.** Agent Keyring now checks for updates automatically in the background with Sparkle 2 and downloads signed updates over HTTPS.

### What is in 1.0.1

- **Sparkle 2 automatic updates:** The Mac app checks `https://keyring.opentrawl.sh/appcast.xml`, verifies every update with its Ed25519 signing key, and installs updates automatically.
- **Check for Updates action:** Available in the Agent Keyring app menu and the menu bar popover's More menu whenever you want to check manually.
- **Hardened release pipeline:** Release builds verify the embedded Sparkle framework, sandboxed XPC updater configuration, notarisation, and Ed25519 appcast signature before publishing.

### Upgrading from 1.0.0

Because 1.0.0 shipped without Sparkle, existing 1.0.0 users need to download and install 1.0.1 once manually from this release. Every update from 1.0.1 onward installs automatically through Sparkle.
