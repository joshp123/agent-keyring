# Agent Keyring

**1Password for the Agentic OS.** Let your AI agents sign in as you anywhere you work, using the passwords you already keep in Apple Passwords, with your approval.

Part of the [OpenTrawl](https://github.com/opentrawl/opentrawl) suite alongside OpenTrawl (**Spotlight for the Agentic OS**). See [agent-keyring.jjpcodes.com](https://agent-keyring.jjpcodes.com/) for the overview, [security model](https://agent-keyring.jjpcodes.com/security/), and [comparisons](https://agent-keyring.jjpcodes.com/compare/).

macOS 26 or later · MIT licence

**Status:** `0.5.0` is live on [Releases](https://github.com/opentrawl/agent-keyring/releases/latest) as a signed, notarised Mac app. Today, `0.5.0` works on your Mac (Touch ID approvals) and enrolled computers on your Tailscale network (Automatic passwords). The iPhone and Apple Watch approval app is in internal testing before public TestFlight; join the waitlist at [agent-keyring.jjpcodes.com](https://agent-keyring.jjpcodes.com/).

## Get started

1. **Install Agent Keyring** on your Mac from [Releases](https://github.com/opentrawl/agent-keyring/releases/latest) (or ask your coding agent to build it from this repo using [CONTRIBUTING.md](CONTRIBUTING.md)).
2. **Export your passwords** from Apple Passwords into Agent Keyring (`File -> Export All Items to App -> Agent Keyring`). Every password starts on **Ask**.
3. **Hand it to your AI.** Paste this into your agent:

> Set up Agent Keyring for me. Run `"/Applications/Agent Keyring.app/Contents/Helpers/agent-keyring" skill` and follow its setup section.

Your agent inspects your setup, asks before changing anything, pairs your other computers over Tailscale, and tells you any manual step it cannot do itself (such as loading the Chrome extension or installing the CLI on a remote box).

## What your agents can do with it

- **Sign in as you anywhere you work and get things done for you:** Your agents can log in to your real accounts (web portals, airlines, banks, SaaS tools, CLI tools) and finish the job, whether they drive Chrome, Chromium, Brave, Edge, Arc, Safari, a built-in agent browser (Codex, Claude, T3 Code), a desktop app, or a terminal. You approve once for the task; your agent handles retries and authenticator two-factor codes automatically.
- **Keep passwords out of your chat with the browser extension:** In Chrome, Chromium, Brave, Edge, and Arc, Agent Keyring's browser extension fills your username, password, and two-factor code straight into the page, submits, and clears the fields. The password never passes through the model, the chat transcript, or your AI provider's logs, and the extension refuses to type into any site other than the one the password was saved for. In built-in agent browsers, Safari, desktop apps, and CLI tools where Chrome extensions cannot run, your agent signs in under the same approval through `agent-keyring read`. The extension does not stop an agent you already approved from reading the password another way.
- **Run unattended jobs on other computers:** Enroll other Macs, Linux servers, or cloud VMs on your Tailscale network so agents there can sign in with Automatic passwords even while your MacBook is shut.
- **Stop access immediately:** Tap **Stop** in Agent Keyring to cut off an active task approval right away.
- **Coming soon: approve from your iPhone or Apple Watch.** Public TestFlight for the iPhone and Apple Watch companion app is next, so you can approve Ask requests from your phone or wrist even when your MacBook is shut.

## Rules

| Rule | When an agent asks |
| --- | --- |
| **Ask** | You approve or deny with Touch ID on your Mac (and on iPhone or Apple Watch once public TestFlight opens). Every new password starts here; keep anything important (banking, email, cloud, work) on Ask. |
| **Automatic** | For low-stakes sites you do not care about. Your agent signs in as you whenever it wants without asking, even while your MacBook is shut. The password is kept on every enrolled computer, and anything running there can use it. |
| **Blocked** | Refused automatically without bothering you. |

Rules are signed with Touch ID so an agent cannot alter them. In the Mac app, **Set Rules with AI** can suggest rules from your site list (never sending usernames or passwords); you review every change before it applies.

## Who can read what

| Where | What it holds | Who can read it |
| --- | --- | --- |
| Your MacBook | Every imported password, sealed to this Mac's Secure Enclave | Opened only with Touch ID (or macOS companion unlock) |
| Your iPhone (when paired) | Every non-Blocked password, sealed to your iPhone's Secure Enclave | Opened only after Face ID |
| Your Apple Watch (when paired) | No permanent vault; each approval push carries one copy sealed to your Watch's Secure Enclave | Opened only while unlocked on your wrist |
| An enrolled computer (Automatic) | Only passwords set to Automatic, with their two-factor seeds | **Anyone who controls that computer's user account, including agents running there.** Keep sensitive logins on Ask. |
| An Ask password delivered for a task | One password, for one task (up to 30 minutes) | That computer, which can keep it |

Enrolled computers can list every password's name, site, account name, and rule without asking.

Rule changes and device removals take effect immediately on online devices and as soon as offline devices reconnect. Neither takes back a password already delivered, and removing a lost device cannot erase copies already on it. If a device may be compromised, change those passwords and replace their two-factor seeds.

## What it does not do

- It does not sync automatically with Apple Passwords. Apple only allows exports you start yourself, so export again when passwords change.
- It does not handle passkeys, or two-factor codes sent by SMS or email (only authenticator codes saved in Apple Passwords).
- It does not keep a website signed in or sign you out. The 30-minute window only limits how long Agent Keyring will hand out the password for that task.
- It does not isolate a delivered password from software running as the same user on the receiving computer.

## The OpenTrawl suite

- **Agent Keyring** (this repo): 1Password for the Agentic OS. Let your AI agents sign in as you anywhere you work, with your approval.
- **[OpenTrawl](https://github.com/opentrawl/opentrawl)**: Spotlight for the Agentic OS. Give any AI searchable access to your messages, emails, notes, photos, calendar, contacts, finances, and X history.

## Contributing and building from source

Agent Keyring is open source (MIT). We keep tight architectural control and **do not accept unsolicited feature pull requests**. Read [CONTRIBUTING.md](CONTRIBUTING.md) for bug-fix rules, private security reporting, and developer build instructions.

## Licence

MIT. See [LICENSE](LICENSE).
