# Agent Keyring: Passwords for the Agentic OS

Published: 2026-11-20
Updated: 2026-11-24
Status: signed Mac app available on GitHub Releases (works with Touch ID); v1.1 needs no Tailscale and lets the iPhone work on its own; iPhone and Apple Watch public beta open on TestFlight at https://testflight.apple.com/join/W5xBNeMw
Made by: Josh Palmer (https://x.com/jjpcodes)
Website: https://keyring.opentrawl.sh/
Download (Mac): https://github.com/opentrawl/agent-keyring/releases/latest
Source code: https://github.com/opentrawl/agent-keyring
Licence: MIT (free)
Security: /security.md (https://keyring.opentrawl.sh/security.md)
Comparison: /compare.md (https://keyring.opentrawl.sh/compare.md)
Privacy: /privacy.md (https://keyring.opentrawl.sh/privacy.md)
Full context: /llms-full.txt (https://keyring.opentrawl.sh/llms-full.txt)

Your agents ask. You tap yes.

Passwords for the Agentic OS, part of the OpenTrawl suite (https://github.com/opentrawl). Let Claude Code, Codex or any AI agent sign in to websites with the passwords you keep in Apple Passwords, approved with Touch ID, Face ID or your Apple Watch.

## The walkthrough

The home page plays four short scenes.

1. Apple Watch. You're out on your bike. Claude Code, on the Mac mini at home, needs to sign in to openai.com to top up API credits. Your Apple Watch shows the website, the account and the reason. You tap Approve, and Claude Code signs in and carries on.
2. Mac. You're at your desk. Codex needs a password and a two-factor code for hetzner.com to download last month's invoices. You click Approve and use Touch ID. One approval covers both.
3. iPhone. You're on the toilet. Claude Code, on a Linux server, asks for your github.com password to make a new access token. You deny it and say "No. Use the gh CLI." Claude Code gets your reply and uses gh instead.
4. Without Agent Keyring. The same top-up task stalls for more than two hours, until you get home and sign in yourself.

## Set it up

There are two installs. The app goes on your own Mac with Touch ID, your iPhone and your Apple Watch: it holds your passwords and asks you to approve. Every Mac and iPhone is an equal: import from Apple Passwords on any of them and their lists merge through your own iCloud. No Mac? The iPhone app works on its own. The `agent-keyring` command goes on the computers your agents run on, such as a headless Mac mini, a Linux server or a cloud VM: it asks for passwords and holds no vault. Don't install the app on a computer that agents control.

On your own Mac, paste one prompt into Claude Code or Codex. Your agent downloads the Mac app, tells you what it suggests next, and asks before touching anything:

> Install and set up Agent Keyring using https://keyring.opentrawl.sh/llms.txt. Tell me what you plan to do and ask before changing anything.

1. Paste the prompt (or download the Mac app). Paste the prompt above into Claude Code or Codex, or download the signed Mac app yourself from GitHub Releases (https://github.com/opentrawl/agent-keyring/releases/latest) (macOS 26 or later). Your agent verifies the checksum, installs it in `/Applications`, and asks before changing anything else.
2. Copy your passwords from Apple Passwords. In Apple Passwords, choose File > Export All Items to App… and pick Agent Keyring. Nothing is deleted from Passwords, and every password starts on Ask so no agent gets one until you approve.
3. Let your agent wire up the rest (with your say-so). Your agent reads `agent-keyring skill`, tells you what it recommends, and asks before touching your Chrome-family browser extension, enrolling Linux or Mac servers, or connecting your iPhone and Apple Watch (join the TestFlight beta at https://testflight.apple.com/join/W5xBNeMw or build from source).

With only an iPhone: open the app, tap Set Up on This iPhone, then in Apple Passwords tap Export Data to Another App and choose Agent Keyring. Add your Apple Watch and your agent computers from the iPhone's Devices tab.

## Each password has a rule

Every password starts on Ask. Change the rule whenever you like.

- Ask: an agent has to ask, and you approve or deny. One approval covers that one password for that one task, 30 minutes at most.
- Automatic: agents on the computers you choose get it without asking. Use it for a password you'd leave on that computer anyway, like the one for a staging site.
- Blocked: once a computer receives the rule, it refuses every request. Good for your bank and your email.

## How it works

Your agent runs a command, `agent-keyring`, and asks for one password by website. You see the website, the account, which agent on which computer is asking, and its reason. Approve, and Agent Keyring signs in for that task. There's no account and no vault of ours: your passwords stay encrypted on your own devices, and your Apple devices keep each other up to date through your own iCloud. We can't read your passwords, Apple can't read them, and your internet provider can't read them.

When an agent on another computer asks for approval, requests and answers pass through our zero-data-retention relay at `push.opentrawl.sh`: zero per-request logs, no box IDs or tokens in URLs, and AES-256-GCM encrypted boxes deleted the moment they're picked up. You can also self-host it with `agent-keyring-box`.

The computer your agent runs on (a Mac or a Linux server) sends the website, the account and the agent's reason to your devices (Mac, iPhone and Apple Watch). A Blocked password stops there. An approved request sends back one password, for one task, 30 minutes at most.

- Your passwords are encrypted on your own devices. Your Mac and iPhone encrypt their approval copies with keys kept in the Secure Enclave, the chip behind Touch ID and Face ID. Those keys can't leave the chip. A copy sent to another of your devices through iCloud is encrypted to that device's key first, so iCloud only ever holds ciphertext. A computer allowed to use an Automatic password keeps a copy it can open itself.
- Works in any browser, app or CLI. You just approve the request; your agent picks the right way to sign in. When it's in Chrome, Brave, Edge, Arc or Chromium with the extension loaded, the extension types the password straight into the form. In Safari, built-in agent browsers, desktop apps (via computer use) or CLI tools, your agent passes the approved password straight into the tool or app.
- One approval, one password, one task. An approval covers retries and ends when the agent releases it, when the computer receives your Stop, or after 30 minutes at most.
- Two-factor codes work too. If you set up a site's two-factor code in Apple Passwords, Agent Keyring fills it in along with the password. For an Ask password, your agent never gets the setup key, so it can't make codes of its own later.

Security details: /security.md

## Already use Apple Passwords?

Then you don't need a second password manager, a new account or a subscription. Checked November 2026:

| | Agent Keyring | 1Password for Agents | Bitwarden Agent Access |
| --- | --- | --- | --- |
| Where your passwords live | Apple Passwords | 1Password | Bitwarden |
| Cost | Free and open source (MIT) | An individual or family account on 1Password.com | Free and open source |
| Agents it works with | Claude Code, Codex and anything else that can run a shell command | Five partner apps. Not Claude Code or Codex | Anything that can run a shell command |
| Where you approve | Mac, iPhone or Apple Watch | The 1Password app, on the device the agent runs on | A terminal you keep open |
| What one approval covers | One password for one task, 30 minutes at most | One login, for up to 30 days | One request, or repeat requests from the same device for a time you choose |

Full comparison: /compare.md

## Questions

- Does my Mac have to stay awake? No. Your iPhone keeps its own encrypted copy of your passwords, and an agent on another computer sends its request straight to your iPhone and Apple Watch. That agent can sign in while your MacBook is shut in a bag.
- Can I use a Mac mini or Mac Studio without Touch ID? Yes, two ways. If agents run on it, install only the `agent-keyring` command and add it from your Mac or iPhone with a one-time code. If it is your own personal Mac, the app asks how you use it and you can opt in to approving with your Mac password. Your passwords stay locked to its Secure Enclave, and no agent can open an Ask password without macOS asking for your Mac password, but a typed password is weaker than Touch ID or Face ID: an agent or tool that knows your Mac login password could approve its own requests.
- How do my Mac and iPhone find each other? Through your own iCloud Keychain, which Apple encrypts end to end. After that they keep each other up to date through your own iCloud. There is no account with us.
- Do I need a Mac? No. The iPhone app can hold your passwords on its own: export from Apple Passwords on the iPhone, add your Apple Watch, and add agent computers with a one-time code.
- Do I need Tailscale? No. Agent computers join with a one-time code (`agent-keyring enrol --code`). Requests and answers pass through our zero-data-retention relay of AES-256-GCM encrypted boxes, which runs with zero per-request logs, keeps box IDs and access tokens out of URLs, deletes each box when it is picked up, stops serving unread boxes when their time runs out, and lets AWS remove expired rows from DynamoDB automatically (usually within a few days). You can run your own with `agent-keyring-box`.
- What does zero data retention mean on the relay? The relay Lambda at `push.opentrawl.sh` has zero `console.*` calls, no CloudWatch Logs permissions in its IAM role, and its CloudWatch log group is destroyed. Requests hit fixed endpoints (`/v1/box`, `/v1/push`) with random box IDs and access tokens sent only in headers (`x-akr-box`, `x-akr-token`), and only hashes of access tokens are kept while a box lives. Unread boxes stop being served at expiry (10 minutes for a join or answer, 45 minutes for an approval grant that Stop marks, 7 days for an update mailbox), after which AWS removes expired rows from DynamoDB automatically, usually within a few days. See /security.md for full details.
- Does it work in Safari, desktop apps, or the browsers built into Codex, Claude and T3 Code? Yes. You approve once, and your agent handles how to sign in: using the browser extension in Chrome-family browsers, or passing the approved password straight into Safari, built-in agent browsers, desktop apps via computer use, or CLI tools.
- What is the Chrome extension for? It lets your agent sign in to Chrome, Brave, Edge, Arc or Chromium without the password touching the agent's own tool output or chat. Your agent uses it automatically when it's available, and falls back to the CLI anywhere else.
- I saved a new password. Does Agent Keyring pick it up? Not by itself. Apple only hands passwords to another app when you start the export, so export again: File > Export All Items to App… on a Mac, or Export Data to Another App on an iPhone. Either one updates every device. You can turn on a reminder, off by default, that comes once your copy is a week old.
- What about passkeys and SMS codes? Neither. Agent Keyring handles passwords and the two-factor codes Apple Passwords generates. It can't use passkeys or read codes sent by SMS or email.

## Join the iPhone and Apple Watch beta

The signed Mac app is out on GitHub Releases (https://github.com/opentrawl/agent-keyring/releases/latest) and works straight away with Touch ID. The iPhone and Apple Watch apps are in public beta on TestFlight: open https://testflight.apple.com/join/W5xBNeMw on your iPhone to install them. Source code: https://github.com/opentrawl/agent-keyring
