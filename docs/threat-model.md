---
written_by: ai (Claude Opus 5.5, 2026-11-19), replacing the version of 2026-10-12; covers the sealed-password design (proto/agentkeyring/v2/keyring.proto)
---

# Threat model: what Agent Keyring protects against

Your agents need your passwords to sign in to websites for you. Agent Keyring gives one agent one password for one task, for 30 minutes at most, when you approve it on your Mac with Touch ID, on your iPhone with Face ID, or on your Apple Watch. The aim is that a tricked agent, a rogue program on one of your computers, or a broken-into Mac mini cannot get a password you did not approve, and cannot make you approve something other than what you see.

## Where your passwords are

Each password is sealed separately to each device that may approve it: this Mac, your iPhone and your Apple Watch. A device opens its copy only after your finger, face or a tap on your wrist. A password set to Automatic is also sealed to each computer you allowed to use Automatic passwords. The Mac mini passes requests and answers between computers and devices; it holds sealed copies it cannot open.

## What you see, and how far to trust it

| Shown | Where it comes from | Trust |
| --- | --- | --- |
| The password: site, account and name | Your own signed list of passwords, and the sealed copy, which carries the same name, sites and account inside it | Fact. A copy that does not match is refused before you see it. |
| The computer that asked | The request, signed by that computer's own key | Fact. |
| The agent, project and reason | Written by the agent | The agent's claim. A tricked agent can write anything here. |

## Threats

| Threat | Example | Defence | What remains |
| --- | --- | --- | --- |
| A trusted agent is tricked by a page or document | Claude Code reads a page that tells it to sign in to your bank | Your rules (Blocked or Ask); the request shows the real site; one approval covers one password for 30 minutes | You approve what you are shown. |
| A program on another computer asks | A script on the Linux server runs `agent-keyring lease` | It can ask only as that computer, and you see which computer asked | It can ask like any agent there. |
| The Mac mini is broken into | Someone controls the program that passes requests | It cannot open a sealed password. It cannot make up a request or send your approval to another computer, because the asking computer signs each request. It cannot make up, relabel or roll back a sealed password, because the device that sealed it signs it and your signed list names its version. It cannot bring back an older list of passwords or rules, because every computer and device keeps the newest it has seen. It cannot make up an answer, because your device signs it. | It can delay or drop requests, and see which password a computer asks for and when. A broken-into Mac mini can ask as the Mac mini. |
| A rogue program on your Mac edits Agent Keyring's files | It renames your bank password to example.com, or points the app at its own relay | The relay's address and key, your devices and computers, and your rules are in the app's own keychain, which other programs cannot change. Each sealed copy carries its own name, sites and account, so if the list on disk has been changed, your touch opens nothing and no password is released. | It can ask like any agent on your Mac, and a changed list on disk can make macOS's dialog name the wrong site (your touch then releases nothing). |
| A stolen or replayed approval | Someone re-sends yesterday's approval | Each answer is signed by your device, covers one request's exact bytes, lasts 30 minutes, and its password is sealed to the asking computer's key | None. |
| An agent asks again and again | 20 requests in a minute | A denial holds that password off for that computer for 30 minutes; one approval covers it for 30 minutes | Fatigue is real. |
| A lost iPhone or Apple Watch | Your iPhone is stolen | Its keys work only after Face ID, or on your wrist. Remove it in Devices on another device: the Mac mini deletes its copies. Your passwords stay in Apple Passwords. | None. |
| Someone at your unlocked Mac | | Out of scope: anyone at your unlocked Mac is you, as far as macOS is concerned | Lock your Mac. |

## Limiting the damage

- **An agent that reads a password knows it.** One approval covers filling and reading for 30 minutes; after that the agent cannot ask the password from Agent Keyring again without you.
- **One-time codes.** The secret that makes them never leaves the approving device: the computer gets the codes for the 30 minutes only.
- **Automatic.** Each use is an ordinary 30-minute use that is granted at once. It shows as in use like any approval, and Stop ends it. The computer holds its own sealed copy, so set to Automatic only passwords you would let that computer keep.
- **Blocked.** Setting a password to Blocked deletes every copy except this Mac's own, so no other device or computer holds it.
- **Your words reach the agent.** Deny with a note ("use the gh command instead") and the agent changes course.
