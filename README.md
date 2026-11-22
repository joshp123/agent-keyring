# Agent Keyring

Agent Keyring lets your AI agents sign in to websites with the logins you keep
in Apple Passwords, with your approval. When it fills a browser or hands the
password to a program, the password does not pass through the agent's chat.

An agent asks for one login for the task it is doing. Your rule for that login
decides: approve automatically, ask you, or refuse. If you are asked, you
approve with Touch ID on your Mac, or on your iPhone when you are away. The
agent then signs in through Agent Keyring and carries on.

macOS 26 or later · MIT licence

**Status.** `main` is version 0.5.0 (direct peer architecture over Tailscale, with Mac, iPhone, Apple Watch, and Linux/macOS CLI).

## What it does today

- **One approval per task.** An approval lets Agent Keyring deliver that login
  for the agent's task: retries, browser filling, reading, and two-factor steps
  included, until the agent says it is done, you tap Stop, or 30 minutes pass.
  After that the agent must ask again. Logins set to Automatic are approved
  without asking.
- **What the 30 minutes means.** It is how long Agent Keyring will hand out the
  login for that task. It does not take back a password the agent's machine
  has already received, and it does not sign anyone out of the website.
- **A browser extension fills the login.** You load it once in each browser
  profile; the installer registers its helper with Chrome, Chromium, Brave,
  Edge and, on a Mac, Arc. The shell commands list its tabs and fields, then
  fill only the controls the agent names, submit and clear them. The extension
  checks the document, frame, and form submission target against the saved site.
- **Direct reading and piping.** `agent-keyring read` prints a field or pipes it
  to another command when a workflow is not in a browser. One approval covers
  both browser filling and reading; use the browser extension when you want to
  keep passwords out of an agent's chat transcript.
- **Two-factor codes** saved with a login in Apple Passwords. Codes sent by
  SMS or email are not handled.
- **Other machines (no relay, no always-on Mac).** Agents on another Mac, a
  Linux server, or a cloud machine on your tailnet ask your iPhone, Apple Watch,
  and Mac directly.
  - **Ask logins** send a time-sensitive Apple push straight from the asking
    computer to your iPhone and Apple Watch (and show on your Mac if awake).
    Your iPhone and Apple Watch hold Secure Enclave-encrypted copies of your
    passwords, so you can approve and deliver straight back to the asking
    computer even when your MacBook is shut.
  - **Automatic logins** are held in encrypted form by each enrolled computer
    allowed to use them, so unattended jobs work even when your MacBook is shut.
  - **Stopping access.** Tapping Stop on your iPhone, Apple Watch, or Mac ends
    an active approval immediately over Tailscale (`agent-keyring hold` keeps
    each remote computer's answer door open while an approval is active). If a
    computer is unreachable, the signed Stop waits at your Mac.

## How direct peer delivery works

Your logins are imported in one place, your MacBook, because Apple Passwords
only exports when you start it. Your MacBook signs the list of devices,
computers, and rules with Touch ID, and encrypts separate copies for each
approving device's Secure Enclave.

Every enrolled computer runs only the `agent-keyring` command (and, for
browsers, the extension). When an agent asks for a password, the asking
computer signs the request, pushes it through Apple Push Notification service
to your iPhone and Apple Watch, and waits on its own Tailscale address (port
17446) for the first signed approval or denial. Nothing sits in the middle and
no always-on Mac is required.

## What it does not do

- Fill Safari, or the browsers built into Codex, Claude and T3. The extension
  cannot be installed in them.
- Keep a website signed in or sign it out. That is the agent's browser.
- Sync with Apple Passwords by itself. Apple only allows an export that you
  start, so you export again when logins change.
- Passkeys.
- Isolate software running as the same OS user on the receiving machine.
  Browser filling keeps passwords out of the agent's conversation and tool
  output; an agent that controls the machine or browser can still read values
  delivered there.

## Who can read what

| Where | What it holds | Who can read it |
| --- | --- | --- |
| Your MacBook's Agent Keyring | Every imported login, sealed to this Mac's Secure Enclave | Opened only with Touch ID (or macOS companion unlock) |
| Your iPhone | Every non-Blocked login, sealed to your iPhone's Secure Enclave | Opened only after Face ID |
| Your Apple Watch | Sealed copies embedded per push, opened by your Watch's Secure Enclave | Opened only while unlocked on your wrist |
| An enrolled computer (Automatic) | Only logins set to Automatic, with their two-factor seeds | **Anyone who controls that computer's user account, including agents running there.** Keep sensitive logins on Ask |
| An Ask login delivered for a task | One login, for one task (up to 30 minutes) | That computer, which can keep it |

Enrolled computers can list every login's name, site, account name and rule
without asking.

Rule changes and removing a device or computer take effect on online devices
right away, and on offline devices as soon as they reconnect. Neither takes
back a password already delivered, and removing a lost device cannot erase a
copy already on it. If a device may be compromised, change those passwords and
replace their two-factor seeds.

## Install

There is no published build of the Mac, iPhone or Apple Watch app for this
version yet.

### The command on your other computers

Agents on a computer other than your Mac, such as a Linux server or a Mac
without the app, need only the `agent-keyring` command. It is one program, and
the instructions agents follow are built in: `agent-keyring skill` prints them.
Install it in one of two ways. Both work on Linux and on macOS.

With [Nix](https://nixos.org), flakes enabled:

```sh
nix profile add github:joshp123/agent-keyring#agent-keyring
```

Older versions of Nix call this `nix profile install`. To run it once without
installing, use `nix run github:joshp123/agent-keyring#agent-keyring -- --help`.

With Go 1.26 or later:

```sh
git clone https://github.com/joshp123/agent-keyring.git
cd agent-keyring
mkdir -p ~/.local/bin
CGO_ENABLED=0 go build -o ~/.local/bin/agent-keyring ./cmd/agent-keyring
```

Make sure `~/.local/bin` is on your `PATH`, or build into another folder that
is.

Then join the computer directly to your Mac over Tailscale. On the Mac, get a
link that works once, for 10 minutes (or open Devices and choose Add Another
Computer):

```sh
"/Applications/Agent Keyring.app/Contents/Helpers/agent-keyring" invite
```

On the other computer, run:

```sh
agent-keyring enrol --name "Linux server" --invite 'LINK'
```

Approve the computer on your Mac. You can remove it later in Devices.

## For agents

`agent-keyring skill` prints the instructions agents follow, and
`agent-keyring --help` lists every command. A sign-in looks like this:

```sh
agent-keyring find example.com
lease=$(agent-keyring lease LOGIN_ID --task "$task" --reason "What the user asked for")
agent-keyring tabs
agent-keyring fields --tab "$tab"       # use the complete target printed by tabs
agent-keyring fill "$lease" --tab "$tab" \
  --username '#username' --password '#password' --submit 'button[type=submit]'
agent-keyring release "$lease"
```

## Rules

| Rule | When an agent asks |
| --- | --- |
| Ask | You approve or deny, on your Mac or iPhone. New logins start here. |
| Automatic | Approved without asking, and recorded. |
| Blocked | Refused. You are not asked. |

Rules are signed with a key that needs your Touch ID, so an agent cannot change
them. You can also let an AI suggest rules: in Rules, choose Set Rules with AI.
The prompt contains sites and current rules, never usernames or passwords; a
login with no website appears by its title, which may include a name. You
review every change before it applies.

## Licence

MIT. See [LICENSE](LICENSE).
