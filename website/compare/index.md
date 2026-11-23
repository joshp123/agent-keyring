# How Agent Keyring compares

Published: 2026-11-20
Updated: 2026-11-23
Made by: Josh Palmer (https://x.com/jjpcodes)
HTML page: https://keyring.opentrawl.sh/compare/
Home: /index.md
Security: /security.md
Source code: https://github.com/opentrawl/agent-keyring

1Password, Bitwarden and Proton Pass can each hand a password to an agent, as long as your passwords are in their app. Agent Keyring uses the ones you already keep in Apple Passwords, and you approve on your Mac, iPhone or Apple Watch.

## Side by side

Checked on 22 November 2026 against the 1Password (https://support.1password.com/1password-for-agents/), Bitwarden (https://github.com/bitwarden/agent-access) and Proton Pass (https://proton.me/support/pass-access-tokens) documentation.

| | Agent Keyring | 1Password for Agents | Bitwarden Agent Access | Proton Pass access tokens |
| --- | --- | --- | --- | --- |
| Where your passwords live | Apple Passwords. You copy them to your Mac, and again when one changes | 1Password | Bitwarden. The protocol is open to other password managers | Proton Pass |
| Cost | Free and open source (MIT) | An individual or family account on 1Password.com | Free and open source | A Proton plan that includes Pass access tokens |
| Agents it works with | Claude Code, Codex and anything else that can run a shell command | Five partner apps: Claude Duet, Grok Bot, Instinct, Muse and Town | Anything that can run a shell command | Anything that can run the Proton Pass command-line tool |
| Where you approve | Mac (Touch ID), iPhone (Face ID) or Apple Watch (one tap) | The 1Password app, on the device the agent runs on | The terminal running `aac listen` | Nowhere. You choose vaults when you make the token |
| What one approval covers | One password for one task, 30 minutes at most | One login, for up to 30 days | One request, or repeat requests from the same device for a time you choose | Every item in the vaults you chose, for 1 hour to 1 year |
| Can the agent read the password? | Not in chat when the agent fills via the browser extension (an agent controlling that browser can still read the filled field). Yes when the agent falls back to the CLI for other browsers, computer use or CLI tools | No. 1Password fills it outside the agent's view | Yes, unless it uses `aac run`, which passes it to a program instead | Yes |
| What you can answer | Approve, deny, or deny and tell the agent what to do instead, typed or spoken | Approve, pick a different login, or deny | Approve once, approve repeats for a time you choose, or deny | Nothing to answer |
| Agents on a Linux server | Yes, over Tailscale | Only where the 1Password app and a partner app both run | Yes, through a relay that can't read the traffic | Yes |

## Choose Agent Keyring if

Your passwords are in Apple Passwords, you work on a Mac, and your agents are Claude Code, Codex or anything else that runs shell commands, on that Mac or on a Linux server.

## Choose something else if

Your passwords already live in 1Password, Bitwarden or Proton Pass, you need shared team vaults, or you want to approve from Android or Windows.
