---
written_by: AI on 2026.11.23 by model gemini-4-neon for the v0.5.0 public Mac release
---

**1Password for the Agentic OS.** Let your AI agents sign in as you anywhere you work, using the passwords you already keep in Apple Passwords, with your Touch ID approval.

### What is in 0.5.0

- **Mac app with Touch ID approvals (macOS 26+):** Export your passwords from Apple Passwords into Agent Keyring. Every password starts on **Ask**, sealed to your Mac's Secure Enclave. When an agent asks to sign in, a floating approval panel appears beside your active window showing the real site, account and the agent's reason; approve with Touch ID or deny with a note.
- **30-minute task leases:** One approval covers username, password, authenticator two-factor codes and retries for up to 30 minutes, and you can cut access off immediately with **Stop**.
- **Chrome-family browser extension + CLI delivery:** Load the bundled extension (`Agent Keyring.app/Contents/Resources/AgentTools/BrowserExtension`) in Chrome, Chromium, Brave, Edge or Arc so Agent Keyring fills, submits and clears sign-in forms without the password passing through the model, chat transcript or provider logs. In Safari, built-in agent browsers, desktop apps and terminals, approved agents use `agent-keyring read`.
- **Enrolled computers over Tailscale:** Add other Macs, Linux servers or cloud VMs over Tailscale (direct TLS 1.3, pinned by public key, no relay) so unattended agents there can use **Automatic** passwords even while your MacBook is shut.
- **Rules signed with Touch ID:** Set each password to **Ask**, **Automatic** or **Blocked**, or use **Set Rules with AI** to sort your site list (never sending usernames or passwords) and review every change before signing.
- **Agent-driven setup:** Paste the setup prompt from the README into your agent; it runs `agent-keyring skill`, proposes what to configure and asks permission before scanning Tailscale, probing SSH hosts or changing anything.

### Coming next

- **iPhone and Apple Watch approval app:** Currently in internal testing before public TestFlight. Join the waitlist at [agent-keyring.jjpcodes.com](https://agent-keyring.jjpcodes.com/).
