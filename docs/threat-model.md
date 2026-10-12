---
written_by: ai (Claude Opus 5.5, 2026-10-12), from Josh's steering; covers local agents; cloud agents are in rfc/0003-cloud-agents-risk.md
---

# Threat model: is it safe to grant this agent?

When a request reaches your phone, you are deciding whether *this* agent, on *this* machine, should get *this* login, now. Agent Keyring cannot read an agent's intentions. It can show you facts the agent cannot fake, flag what looks wrong, and keep the blast radius small if you approve something you should not have.

## What you see, and how much to trust it

| Shown | Source | Trust |
| --- | --- | --- |
| Agent: "Claude Code, verified (Anthropic)" | The code signature of the agent program that started the request, checked by Agent Keyring | Fact. A script claiming to be Claude Code shows as **Unverified** in red. |
| Machine: "Josh's MacBook Pro", folder `~/code/nixos-config`, address 192.168.1.20 | Read by Agent Keyring on the Mac from the requesting process | Fact for local agents. |
| Site, account, field (password, code or username) | Agent Keyring's own lookup | Fact. Fill also checks the page belongs to this site before typing. |
| "Why" and "Your request" | Written by the agent | **The agent's claim.** Labelled as such. A tricked agent can write anything here. |
| Flags: first time this agent asked for this login, a login you marked sensitive, many requests | Agent Keyring's own records | Fact. Sensitive is your mark (the rules assistant can suggest it), never a guess from the site's name. |

Everything shown is also what your phone signs, so the Mac releases only what you saw.

## Threats

| Threat | Example | Defence | What remains |
| --- | --- | --- | --- |
| A trusted agent is tricked by a web page or document | Claude Code reads a page that tells it to sign in to your bank | Your rules (bank set to Blocked or Ask); the request shows the site and flags logins you marked sensitive and first-time requests; the agent's "why" usually will not fit | You approve what you are shown. Context helps; it cannot be perfect. |
| Another program pretends to be your agent | A malicious script runs the `agent-keyring` command and labels itself "Claude Code" | The code-signature check marks it **Unverified**; Agent Keyring refuses unverified requesters for logins set to Allow automatically | A program you installed yourself and signed can still ask; it will be named. |
| A phishing page | The agent is steered to github-login.example.com | Fill types only where the page belongs to the saved site; the agent-browser plugin checks the origin | — |
| An agent asks over and over until you tap yes | 20 requests in a minute | Requests for the same login join one prompt; many requests are flagged; one approval covers that login for 30 minutes, so there is no need to keep asking | Fatigue is real. Shorter grants and per-site rules reduce it. |
| A stolen or replayed approval | Someone with iCloud access re-sends yesterday's "Approve" | Each answer is signed by your iPhone's Secure Enclave, bound to one request, single-use and expiring | — |
| An agent edits your rules | It changes your bank from Blocked to Allow | Rules are signed with your Touch ID; edits stop all releases until you confirm | — |
| Someone with your unlocked Mac | — | Out of scope: anyone at your unlocked Mac is you, as far as macOS is concerned | Lock your Mac. |

## Limiting the damage

- **Fill, don't reveal.** The agent never holds the password, so it cannot paste it elsewhere later.
- **Per-login, per-action, 30-minute grants.** Approving a fill never allows a plaintext `acquire`.
- **Your words reach the agent.** Deny with a note ("use the gh CLI instead") so the agent changes course rather than retrying.
- **Sensitive logins.** Mark email, banks and Apple ID as sensitive and keep them on Blocked or Ask. The rules assistant suggests this; you decide.
