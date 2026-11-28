# Agent Keyring

**Passwords for the Agentic OS.** Let Claude Code, Codex, or any AI agent sign in as you anywhere you work, using the passwords you already keep in Apple Passwords, with your approval.

Part of the [OpenTrawl](https://github.com/opentrawl/opentrawl) suite alongside OpenTrawl (**Spotlight for the Agentic OS**). See [keyring.opentrawl.sh](https://keyring.opentrawl.sh/) for the overview, [security model](https://keyring.opentrawl.sh/security/), and [comparisons](https://keyring.opentrawl.sh/compare/).

macOS 26 or later · MIT licence

**Status:** the signed, notarised Mac app and standalone Linux/macOS CLI binaries are on [Releases](https://github.com/opentrawl/agent-keyring/releases/latest). Version `1.1.0` needs no Tailscale, syncs your Apple devices through your own iCloud, and lets your iPhone work on its own, with no Mac. The iPhone and Apple Watch approval app is in public beta on [TestFlight](https://testflight.apple.com/join/W5xBNeMw).

## Two installs: the app and the command

| Install | Where it goes | What it does |
| --- | --- | --- |
| **The app** (`Agent Keyring.app`, and the iPhone and Apple Watch app) | Your own Mac with Touch ID, your iPhone and your Apple Watch. Any of your Macs and iPhones can import from Apple Passwords; none is in charge. | Holds your passwords, encrypted to each device's Secure Enclave, and asks you to approve or deny each request. |
| **The command** (`agent-keyring`) | Computers your agents run on: a headless Mac mini or Mac Studio, a Linux server, a cloud VM | Asks for one password per task. Holds no password vault. Joins with `agent-keyring enrol`. |

Don't install the app on a Mac that agents control. Install only the command there, then add that computer from your Mac or your iPhone (**Devices > Add Another Computer…**), which shows a one-time code for `agent-keyring enrol --code`. On your own Mac, the app already includes the command for agents that run there.

**A personal Mac mini or Mac Studio with no Touch ID:** the app first asks how you use the Mac. **A Mac for agents** gives you the command only. **My personal Mac where I import passwords** is an opt-in: your passwords are still locked to that Mac's Secure Enclave, and no agent can open an Ask password without macOS asking for your Mac password, but a typed password is weaker than Touch ID or Face ID: an agent or tool that knows your Mac login password, for example from a `sudo` prompt, could approve its own requests.

**No Mac?** The iPhone app works on its own: choose **Set Up on This iPhone**, export from Apple Passwords on the iPhone (**Export Data to Another App > Agent Keyring**), add your Apple Watch, and add agent computers with a one-time code.

Your Mac and iPhone find each other through your own iCloud Keychain, and keep each other up to date through your own iCloud, with no account with us. Every Mac and iPhone is an equal: export from Passwords on either and the two lists merge.

## Get started (one prompt)

Paste this into Claude Code, Codex, or any coding agent on your personal Mac:

> Install and set up Agent Keyring using `https://keyring.opentrawl.sh/llms.txt`. Tell me what you plan to do and ask before changing anything.

Your agent downloads and verifies the signed Mac app from Releases, opens it so you can do the two Apple steps yourself (Touch ID + exporting from Apple Passwords via `File -> Export All Items to App -> Agent Keyring`), and then runs `agent-keyring skill` to propose and set up the Chrome extension, remote Linux/Mac servers, and iPhone/Apple Watch pairing.

Prefer to install manually? Download the Mac app zip (`Agent-Keyring-VERSION.zip`) from the latest [Release](https://github.com/opentrawl/agent-keyring/releases/latest), drag `Agent Keyring.app` to `/Applications`, export your passwords from Apple Passwords, and run `"/Applications/Agent Keyring.app/Contents/Helpers/agent-keyring" skill`. Every password starts on **Ask**.

## What your agents can do with it

- **Sign in as you anywhere you work and get things done for you:** Your agents can log in to your real accounts (web portals, airlines, banks, SaaS tools, CLI tools) and finish the job, whether they drive Chrome, Chromium, Brave, Edge, Arc, Safari, a built-in agent browser (Codex, Claude, T3 Code), a desktop app, or a terminal. You approve once for the task; your agent handles retries and authenticator two-factor codes automatically.
- **Keep passwords out of your chat with the browser extension:** In Chrome, Chromium, Brave, Edge, and Arc, Agent Keyring's browser extension fills your username, password, and two-factor code straight into the page, submits, and clears the fields. The password never passes through the model, the chat transcript, or your AI provider's logs, and the extension refuses to type into any site other than the one the password was saved for. In built-in agent browsers, Safari, desktop apps, and CLI tools where Chrome extensions cannot run, your agent signs in under the same approval through `agent-keyring read`. The extension does not stop an agent you already approved from reading the password another way.
- **Run unattended jobs on other computers:** Enrol other Macs, Linux servers, or cloud VMs with a one-time code so agents there can sign in with Automatic passwords even while your MacBook is shut.
- **Stop access immediately:** Tap **Stop** in Agent Keyring to cut off an active task approval right away.
- **Approve from your iPhone or Apple Watch:** Approve Ask requests with Face ID or a tap on your wrist, with or without a Mac.

## How push notifications work

Between your own Macs and iPhones, the signed device list, the signed list of logins and rules, and each device's copies of your passwords travel through your own iCloud private database. Every password is sealed (HPKE) to the receiving device's Secure Enclave key before it leaves the device that exported it, so neither we, Apple, nor your internet provider can read it. The list of sites and account names is kept in CloudKit's encrypted fields, end-to-end encrypted when Advanced Data Protection is on.

Requests and answers between your devices and agent computers go through a zero-data-retention relay of end-to-end encrypted boxes at `https://push.opentrawl.sh`. It sees only random box IDs, which travel in headers, never in URLs, and opaque ciphertext; it is run with no per-request logs, and keeps no accounts or vault. A join or answer box is deleted once picked up; unread boxes stop being served the moment their time runs out (10 minutes for a join or an answer, 45 minutes for the grant that lets you stop an approval, 7 days for a computer's update mailbox), and AWS then deletes expired rows from DynamoDB, usually within a few days. The relay can drop or delay a message, but cannot read or forge one. Run your own with `agent-keyring-box`, behind HTTPS with a certificate your iPhone and Apple Watch trust (such as one from Let's Encrypt).

To wake an iPhone or Apple Watch, Apple Push Notification service (APNs) requires requests to be signed with the app developer's private `.p8` key, which cannot be shipped inside a public download. By default, Agent Keyring sends each already-encrypted push blob through a tiny, stateless blind forwarder at `https://push.opentrawl.sh` (AWS Lambda in `eu-west-1`). That forwarder signs Apple's APNs JWT and hands the opaque ciphertext straight to Apple. It holds no user accounts, no passwords, and no decryption keys: it sees only opaque ciphertext, APNs device tokens, and timestamps, the same metadata Apple sees. If you build the iOS app under your own Apple Developer account, run `agent-keyring push-key` with your own `.p8` file to push directly to Apple with zero intermediary.

To check for new releases and count active users, the Mac and iPhone apps make a single daily `GET` request to `https://push.opentrawl.sh/v1/version` carrying only the app version, platform, CPU architecture, and one stable, anonymous, non-reversible SHA-256 hash (derived from your app-scoped iCloud user ID when signed in so your Mac and iPhone count as one user, or a random local ID otherwise; no IP address, name, Apple ID, site, account, or password is ever sent or stored). Opt out anytime in **Devices** (Mac), **Settings** (iPhone), with `defaults write com.joshpalmer.AgentKeyring.Mac no_telemetry -bool true`, or by setting `AGENT_KEYRING_NO_TELEMETRY=1`.

## Rules

| Rule | When an agent asks |
| --- | --- |
| **Ask** | You approve or deny with Touch ID on your Mac (or your Mac password on a Mac without Touch ID that you opted in), Face ID on your iPhone, or one tap on your Apple Watch. Every new password starts here; keep anything important (banking, email, cloud, work) on Ask. |
| **Automatic** | For low-stakes sites you do not care about. Your agent signs in as you whenever it wants without asking, even while your MacBook is shut. The password is kept on every enrolled computer, and anything running there can use it. |
| **Blocked** | Refused automatically without bothering you. |

Rules are signed only after you approve on your Mac or iPhone, so an agent cannot alter them. A rule changed on one device reaches the others; if two change the same password, the later change wins on every device. In the Mac app, **Set Rules with AI** can suggest rules from your site list (never sending usernames or passwords); you review every change before it applies.

## Who can read what

| Where | What it holds | Who can read it |
| --- | --- | --- |
| Your MacBook | Every imported password except Blocked ones, sealed to this Mac's Secure Enclave | Opened only with Touch ID (or macOS companion unlock) |
| A personal Mac with no Touch ID, opted in to Mac password mode | Every imported password except Blocked ones, sealed to that Mac's Secure Enclave | Opened only after macOS asks for the Mac's login password (or Touch ID, if a Touch ID keyboard is added later) |
| Your iPhone (when paired) | Every non-Blocked password, sealed to your iPhone's Secure Enclave | Opened only after Face ID |
| Your Apple Watch (when added) | Every non-Blocked password, sealed to your Watch's Secure Enclave and sent to it by your iPhone directly. Copies your Mac seals for it pass through your iCloud as ciphertext only the Watch can open. Never to a computer or the relay | Opened only while unlocked on your wrist |
| Your iCloud private database | The signed lists, each device's list of logins (no passwords), and copies sealed to each device's Secure Enclave key | Passwords: only the device each copy is sealed to. Site and account names: you, and Apple unless Advanced Data Protection is on |
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

- **Agent Keyring** (this repo): Passwords for the Agentic OS. Let your AI agents sign in as you anywhere you work, with your approval.
- **[OpenTrawl](https://github.com/opentrawl/opentrawl)**: Spotlight for the Agentic OS. Give any AI searchable access to your messages, emails, notes, photos, calendar, contacts, finances, and X history.

## Contributing and building from source

Agent Keyring is open source (MIT). We keep tight architectural control and **do not accept unsolicited feature pull requests**. Read [CONTRIBUTING.md](CONTRIBUTING.md) for bug-fix rules, private security reporting, and developer build instructions.

## Licence

MIT. See [LICENSE](LICENSE).
