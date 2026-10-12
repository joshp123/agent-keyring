---
written_by: ai (Claude Opus 5.5, 2026-10-12); draft for the next release, to be confirmed after on-device proofs
---

Agent Keyring now fills sign-in forms itself, so agents never see your password.

- **Fill in your browser.** Agents focus a field in Safari, Chrome, Claude's browser pane or Codex's browser and run `agent-keyring fill`. Agent Keyring checks the browser's signature, the page address and the field before typing.
- **Approve from your iPhone.** Pair once with a QR code. When your Mac is locked, or you do not answer within your chosen delay, your iPhone asks instead.
- **Approvals last 30 minutes** per login and action, and agents are told what you are being asked and when.
- **Agents cannot change your rules.** Rules are signed with a Touch ID key; tampering stops all releases until you confirm.
- **Headless sign-in** through the agent-browser plugin, and `sync` when a site rejects a login.
- `copy` is removed; values held for programs now expire after 5 minutes.
