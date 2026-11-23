---
written_by: AI on 2026.11.23 by model gemini-4-neon, updating the 2026-11-19 version by Claude Opus 5.5 for the 0.5.0 direct Tailscale protocol (no relay)
---

# Threat model: what Agent Keyring protects against

Your agents need your passwords to sign in to websites and tools for you. Agent Keyring gives one agent one password for one task, for 30 minutes at most, when you approve it on your Mac with Touch ID (and on iPhone or Apple Watch once paired). The aim is that a tricked agent or a rogue program on one of your computers cannot get a password you did not approve, and cannot make you approve something other than what you see.

## Where your passwords are

There is no cloud server and no relay. Your Mac is the home for your password list and your signed list of devices and computers. Everything travels directly between your devices over your own Tailscale network, over TLS 1.3 pinned by public key.

- **Your Mac:** holds every imported password, sealed to this Mac's Secure Enclave key. Opening a password requires Touch ID (or macOS companion unlock).
- **Your iPhone (when paired):** holds every non-Blocked password, sealed to its Secure Enclave key, opened only after Face ID.
- **Your Apple Watch (when paired):** holds no permanent vault. Each approval notification carries one copy sealed to the Watch's Secure Enclave key, opened only while unlocked on your wrist.
- **Enrolled computers (Automatic passwords):** a password set to Automatic is sealed to every enrolled computer's receiving key, with its two-factor seed. Anyone who controls that computer's user account can read Automatic passwords held there; keep sensitive accounts on Ask.

## What you see, and how far to trust it

| Shown | Where it comes from | Trust |
| --- | --- | --- |
| The password: site, account and name | Your own signed list of passwords, and the sealed copy, which carries the same name, sites and account inside it | Fact. A copy that does not match is refused before you see it. |
| The computer that asked | The request, signed by that computer's own key | Fact. |
| The agent, project and reason | Written by the agent | The agent's claim. A tricked agent can write anything here. |

## Threats

| Threat | Example | Defence | What remains |
| --- | --- | --- | --- |
| A trusted agent is tricked by a page or document | An agent reads a page that tells it to sign in to your bank | Your rules (Blocked or Ask); the request shows the real site; one approval covers one password for 30 minutes | You approve what you are shown. |
| A program on another enrolled computer asks | A script on a Linux server runs `agent-keyring lease` | It can ask only as that computer, and you see which computer asked. It cannot read Ask or Blocked passwords without your approval. | It can read Automatic passwords held on that computer, and ask like any agent there. |
| A rogue program on your Mac edits Agent Keyring's files | It renames your bank password to `example.com` or alters rules on disk | Your rules, signed device list and keys live in the app's own keychain, which other programs cannot edit. Each sealed copy carries its own name, sites and account, so if the list on disk has been tampered with, your touch opens nothing and no password is released. | It can ask like any agent on your Mac, and a changed list on disk can make macOS's dialog name the wrong site (your touch then releases nothing). |
| A stolen or replayed approval | Someone re-sends yesterday's approval | Each answer is signed by your approving device, covers one request's exact bytes, lasts 30 minutes, and seals the password to the asking computer's receiving key | None. |
| An agent asks again and again | 20 requests in a minute | Denying a password holds that computer off for 1 minute, then 5 minutes, then 15 minutes; one approval covers retries for 30 minutes | Fatigue is real. |
| A lost iPhone, Apple Watch or enrolled computer | Your iPhone or Linux server is stolen | iPhone and Watch keys require Face ID or wrist unlock. Remove any lost device or computer in Devices on your Mac to publish a new signed members list and delete its copies on your Mac. | Removing a lost device cannot erase copies already stored on it; change any Automatic passwords (and their two-factor seeds) that were on a compromised computer. |
| Someone at your unlocked Mac | | Out of scope: anyone at your unlocked Mac is you, as far as macOS is concerned | Lock your Mac. |

## Limiting the damage

- **Browser extension vs `agent-keyring read`:** In Chrome, Chromium, Brave, Edge and Arc, the browser extension fills the form, submits and clears the fields without passing the password through the model, chat transcript or provider logs, and refuses to fill any site other than the one saved for that password. In Safari, built-in agent browsers, desktop apps and CLI tools where Chrome extensions cannot run, an approved agent signs in via `agent-keyring read`. The extension does not stop an agent you already approved from reading the password another way.
- **One-time codes:** The secret that generates two-factor codes stays on the approving device for Ask logins: the asking computer receives only the codes for the 30-minute approval window. (Automatic passwords include their two-factor seed on enrolled computers so unattended jobs can sign in.)
- **Automatic:** Each use is an ordinary 30-minute lease granted at once. It appears as active and Stop ends it. Set to Automatic only low-stakes passwords you are comfortable letting enrolled computers hold.
- **Blocked:** Setting a password to Blocked deletes every copy except this Mac's own, so no other device or computer holds it.
- **Your words reach the agent:** Deny with a short note ("use the gh command instead") and the agent receives your exact words.
