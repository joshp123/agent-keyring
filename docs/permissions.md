---
written_by: ai (Claude Opus 5.5, 2026-10-12), from the entitlements and code on main
---

# What Agent Keyring is allowed to do, and why

Each part asks for the least it needs. This lists every permission, what it lets that part do, what it is used for, and what it cannot do.

## On the Mac

| Part | Permission | Used for | Cannot |
| --- | --- | --- | --- |
| Agent Keyring app | App Sandbox | Keeps the app inside its own container. | Read your files, other apps' data or the network beyond what is listed here. |
| | AutoFill credential provider | Lets Apple Passwords hand Agent Keyring your logins when *you* run File → Export All Items to App. | Start an export. Only you can, in Apple Passwords, with Touch ID. |
| | Keychain (its own items only) | Holds the key that encrypts its copy of your logins, the Secure Enclave key that signs your rules, and the rules' fingerprint. | Read other apps' keychain items or your iCloud Keychain. |
| | iCloud (CloudKit, private database) | Sends approval requests to your iPhone and reads its answers. Site and account are encrypted. | Read any other iCloud data. |
| | Notifications | The weekly "your copy is out of date" reminder. | — |
| Fill helper (inside the app) | Accessibility, shown as "Agent Keyring" in System Settings | Reads which browser is in front, the page address and the focused field, then types the login into that field. | Anything for apps other than the verified browsers listed below. It only accepts commands from the Agent Keyring app itself; macOS checks the app's signature on every connection. |
| `agent-keyring` command | None | Passes requests to the app and prints results. | See or store passwords, except values a program asked for with `acquire`, which it pipes on and which expire after 5 minutes. |

**Accessibility, plainly.** Accessibility is a strong macOS permission. A program that has it can read other apps' windows and type into them, and in principle that includes Apple Passwords. Agent Keyring's helper does far less:

- It acts only when the Agent Keyring app asks it to fill.
- It acts only on the browser in front, after checking that browser's code signature (Safari, Chrome, Claude, Codex, Arc, Brave, Edge). It never touches Apple Passwords or any other app.
- It types only into a field on a page that belongs to the saved site, and only while the screen is unlocked.

Even with Accessibility, nothing can export your passwords without your Touch ID: Apple Passwords demands it for every export.

The real exposure is this. If someone replaced the Agent Keyring app with a malicious build signed by your developer certificate, that build would inherit the permission. Keep your developer signing key where agents cannot use it.

Agents that use computer-use tools, such as Claude or Codex, hold their own, separate Accessibility permission. Agent Keyring does not change what they can do.

## On the iPhone

| Permission | Used for |
| --- | --- |
| Camera | Scanning the pairing code on the Mac, once. |
| Notifications, time-sensitive | Showing approval requests even during Focus. |
| iCloud (CloudKit, private database) | Receiving requests and sending your signed answers. |
| Secure Enclave key | Signing each answer. The key never leaves the phone, so a stolen answer cannot be reused for another request. |

The iPhone never receives passwords.

## What only you can do

- **Exporting from Apple Passwords** (File → Export All Items to App → Agent Keyring) needs your Touch ID in Apple Passwords.
- **Changing access rules, pairing or removing an iPhone** needs your Touch ID in Agent Keyring.
- **Granting Accessibility** happens in System Settings.
- **Approving a request** needs your Touch ID or Apple Watch on the Mac, or Face ID and a tap on the iPhone.

No agent can do these for you through Agent Keyring.
