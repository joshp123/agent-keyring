---
written_by: AI on 2026.11.23 by model gemini-4-neon for the v1.0.0 release
---

**Passwords for the Agentic OS.** Let Claude Code, Codex, or any AI agent sign in as you anywhere you work, using the passwords you already keep in Apple Passwords, approved with Touch ID on your Mac or Face ID on your iPhone and Apple Watch.

### What is in 1.0.0

- **One-prompt LLM-first onboarding:** Paste one prompt into Claude Code or Codex (`https://keyring.opentrawl.sh/llms.txt`) and your agent proposes the setup plan, downloads and verifies the signed Mac app, guides your Apple Passwords export, and wires up the Chrome extension and remote computers after asking permission.
- **Blind APNs push forwarder for iPhone and Apple Watch (`push.opentrawl.sh`):** External users get iPhone and Apple Watch push approvals out of the box without needing their own Apple Developer `.p8` key. The stateless forwarder in AWS `eu-west-1` sees only already-encrypted push blobs and device tokens, never passwords, sites, or approvals. Self-builders with their own Apple Developer key can still push directly to Apple.
- **Standalone Linux and macOS CLI binaries:** Release assets now include `agent-keyring-linux-amd64`, `agent-keyring-linux-arm64`, `agent-keyring-darwin-universal`, and `SHA256SUMS.txt` alongside `Agent-Keyring-1.0.0.zip`, so remote servers no longer need Nix.
- **Mac app with Touch ID approvals, 30-minute task leases, and instant Stop:** Signed, notarised, and stapled for macOS 26+, with the Chrome-family browser extension (`AgentTools/BrowserExtension`) and agent skill (`AgentTools/AgentSkill/agent-keyring/SKILL.md`) bundled inside.
- **Zero-PII daily version check:** Checks `https://push.opentrawl.sh/v1/version` at most once per day with version, platform, architecture, and a monthly-rotated anonymous hash (no IP stored, no sites or passwords; disable via `AGENT_KEYRING_NO_TELEMETRY=1` or `defaults write com.joshpalmer.AgentKeyring.Mac disableVersionCheck -bool true`).

### Site & iPhone/Watch Beta

- Website: [keyring.opentrawl.sh](https://keyring.opentrawl.sh/) (also live at [agent-keyring.jjpcodes.com](https://agent-keyring.jjpcodes.com/))
- iPhone and Apple Watch TestFlight beta: open in public beta at [testflight.apple.com/join/W5xBNeMw](https://testflight.apple.com/join/W5xBNeMw).
