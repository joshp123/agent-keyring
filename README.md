# Agent Keyring

**1Password for the Agentic OS.** Let your AI agents sign in as you anywhere you work, using the passwords you already keep in Apple Passwords, with your approval.

Part of the [OpenTrawl](https://github.com/opentrawl/opentrawl) suite alongside OpenTrawl (**Spotlight for the Agentic OS**). See [keyring.opentrawl.sh](https://keyring.opentrawl.sh/) for the overview, [security model](https://keyring.opentrawl.sh/security/), and [comparisons](https://keyring.opentrawl.sh/compare/).

macOS 26 or later · MIT licence

**Status:** `1.0.0` is live on [Releases](https://github.com/opentrawl/agent-keyring/releases/latest) with the signed, notarised Mac app and standalone Linux/macOS CLI binaries. The iPhone and Apple Watch approval app is submitted for external TestFlight Beta App Review; join the waitlist at [keyring.opentrawl.sh](https://keyring.opentrawl.sh/#waitlist) to get the public TestFlight link as soon as Apple approves.

## Get started (one prompt)

Paste this into Claude Code, Codex, or any coding agent on your Mac:

> Install and set up Agent Keyring using `https://keyring.opentrawl.sh/llms.txt`. Tell me what you plan to do and ask before scanning my network or changing anything.

Your agent downloads and verifies the signed Mac app from Releases, opens it so you can do the two Apple steps yourself (Touch ID + exporting from Apple Passwords via `File -> Export All Items to App -> Agent Keyring`), and then runs `agent-keyring skill` to propose and set up the Chrome extension, remote Linux/Mac servers, and iPhone/Apple Watch pairing.

Prefer to install manually? Download `Agent-Keyring-1.0.0.zip` from [Releases](https://github.com/opentrawl/agent-keyring/releases/latest), drag `Agent Keyring.app` to `/Applications`, export your passwords from Apple Passwords, and run `"/Applications/Agent Keyring.app/Contents/Helpers/agent-keyring" skill`. Every password starts on **Ask**.

## What your agents can do with it

- **Sign in as you anywhere you work and get things done for you:** Your agents can log in to your real accounts (web portals, airlines, banks, SaaS tools, CLI tools) and finish the job, whether they drive Chrome, Chromium, Brave, Edge, Arc, Safari, a built-in agent browser (Codex, Claude, T3 Code), a desktop app, or a terminal. You approve once for the task; your agent handles retries and authenticator two-factor codes automatically.
- **Keep passwords out of your chat with the browser extension:** In Chrome, Chromium, Brave, Edge, and Arc, Agent Keyring's browser extension fills your username, password, and two-factor code straight into the page, submits, and clears the fields. The password never passes through the model, the chat transcript, or your AI provider's logs, and the extension refuses to type into any site other than the one the password was saved for. In built-in agent browsers, Safari, desktop apps, and CLI tools where Chrome extensions cannot run, your agent signs in under the same approval through `agent-keyring read`. The extension does not stop an agent you already approved from reading the password another way.
- **Run unattended jobs on other computers:** Enroll other Macs, Linux servers, or cloud VMs on your Tailscale network so agents there can sign in with Automatic passwords even while your MacBook is shut.
- **Stop access immediately:** Tap **Stop** in Agent Keyring to cut off an active task approval right away.
- **Approve from your iPhone or Apple Watch:** Pair your iPhone and Apple Watch over Tailscale so you can approve Ask requests with Face ID or a tap on your wrist even when your MacBook is shut.

## How push notifications work

Your passwords, device lists, and approvals travel directly between your own devices over your Tailscale network (TLS 1.3 pinned by public key) with no cloud vault.

To wake an iPhone or Apple Watch, Apple Push Notification service (APNs) requires requests to be signed with the app developer's private `.p8` key, which cannot be shipped inside a public download. By default, Agent Keyring sends each already-encrypted push blob through a tiny, stateless blind forwarder at `https://push.opentrawl.sh` (AWS Lambda in `eu-west-1`). That forwarder signs Apple's APNs JWT and hands the opaque ciphertext straight to Apple. It holds no user accounts, no passwords, and no decryption keys: it sees only opaque ciphertext, APNs device tokens, and timestamps, the same metadata Apple sees. If you build the iOS app under your own Apple Developer account, run `agent-keyring push-key` with your own `.p8` file to push directly to Apple with zero intermediary.

To check for new releases and count active installs, the Mac and iPhone apps make a single daily `GET` request to `https://push.opentrawl.sh/v1/version` carrying only the app version, platform, CPU architecture, and a monthly-rotated anonymous hash (no IP address is stored, and no sites, accounts, or passwords are ever sent). Disable it anytime with `AGENT_KEYRING_NO_TELEMETRY=1` or `defaults write com.joshpalmer.AgentKeyring.Mac disableVersionCheck -bool true`.

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
