---
written_by: ai (Claude Opus 5.5, 2026-10-12), from RFC 0002 and Fable's 2026-10-12 review; not built yet
---

# Cloud agents: risk profile

**Status: pending.** Nothing for cloud agents is built. Agent Keyring today serves agents running on your Mac. This document says what the cloud case risks, what the design already covers, and what must be decided before building it.

## The use case

Grok bot and Muse run on someone else's servers. When they need to sign in to one of your accounts, the credential, or something that stands in for it, has to reach them. Locally, the password never leaves your Mac. In the cloud case that promise can only be kept for some kinds of task.

## Ways to give a cloud agent access, safest first

| Option | What leaves your Mac | Residual risk |
| --- | --- | --- |
| 1. Signed-in session | A session cookie or token for one site, not the password. | Whoever holds the session can act as you on that site until it expires or you sign out. Your password stays home. |
| 2. API relay you control | Nothing. The agent's API calls go through a relay that adds the key. | The relay is a new service that must be secured, and the agent can still do anything the key allows while the relay accepts its calls. |
| 3. Password sent to a fill component | The password, encrypted end to end to a small Agent Keyring component in the cloud environment, which fills the form and discards it. | Once the password is on someone else's machine, a compromised host or runtime could keep it. Encryption protects it on the way, not on arrival. |

The rule should be: the first option that works for the site. The password goes to the cloud only when the site offers no session or API route, and only for that one sign-in.

## Threats, and what the design does about them

| Threat | Designed mitigation | Still open |
| --- | --- | --- |
| A prompt-injected cloud agent asks for logins it should not have | Every cloud request needs your iPhone approval. "Allow automatically" applies to local agents only. | Approval fatigue: you approve what you are shown. Showing the agent, site, account and reason, and throttling repeat requests, are not designed yet. |
| Someone impersonates your agent | Each cloud agent is paired once with its own key and signs every request; the phone and the agent's chat show the same short code. | No paired-agent registry exists yet. Today an agent's identity is just a process name. |
| A stolen approval is replayed | Decisions are signed by your iPhone's Secure Enclave, bound to one request, single-use and short-lived. This is already built for local requests. | — |
| The relay or channel is read | End-to-end encryption, with a relay that cannot read traffic, following Bitwarden Agent Access. | No relay exists. Your iCloud database is yours alone, so cloud agents cannot use it. This is a new service. |
| A cloud host keeps a password it was sent | Option 3 is used only when nothing safer works; the release is single-use and logged. | Irreducible for option 3. The only full answer is never sending passwords: prefer sessions and relays. |
| Your Mac is off or asleep | — | Everything is released from your Mac, so nothing works while it is off. Accept that, or plan an always-on home for the keyring. |
| Your phone is lost | Removing a phone needs Touch ID on the Mac, and approvals need Face ID on the phone. | Revoking a cloud agent from the phone is designed, not built. |

## Decisions needed before building

1. **Transport.** Where does a cloud agent send its request? Options: a relay you run (on your tailnet, or a small hosted service), or adopting Bitwarden's Agent Access protocol and relay.
2. **Agent identity.** How is each cloud agent paired and revoked? Proposal: the same QR-and-code pairing as the iPhone, stored in the same signed store.
3. **Portability.** The cloud component must run on Linux. Today's plugin is macOS-only Swift. It needs a small portable component, plus key agreement for the encryption.
4. **Availability.** Must your Mac stay awake for cloud agents to work, or does the keyring need an always-on home?

## What is reusable now

- The signed approval request and decision format.
- The Mac-side verifier: single-use, replay-proof and expiring.
- The signed, rollback-proof store that holds paired devices.
- The iPhone approval app.
- The agent-browser credential plugin contract.
