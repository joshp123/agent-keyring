# Agent Keyring

Agent Keyring lets your AI agents sign in to websites with the logins you keep
in Apple Passwords, with your approval. When it fills a browser or hands the
password to a program, the password does not pass through the agent's chat.

An agent asks for one login for the task it is doing. Your rule for that login
decides: approve automatically, ask you, or refuse. If you are asked, you
approve with Touch ID on your Mac, or on your iPhone when you are away. The
agent then signs in through Agent Keyring and carries on.

macOS 26 or later · MIT licence

**Status.** `main` is version 0.3.0 and is not yet published as a release. The
last published release, 0.2.1, works differently and this page does not
describe it.

## What it does today

- **One approval per task.** An approval lets Agent Keyring deliver that login
  for the agent's task: retries and two-factor steps included, until the agent
  says it is done or 30 minutes after you approved. After that the agent must
  ask again. Logins set to Automatic are approved again without asking.
- **What the 30 minutes means.** It is how long Agent Keyring will hand out the
  login for that task. It does not take back a password the agent's machine
  has already received, and it does not sign anyone out of the website.
- **A browser extension fills the login.** You load it once in each browser
  profile; the installer registers its helper with Chrome, Chromium, Brave,
  Edge and, on a Mac, Arc. The shell commands list
  its tabs and fields, then fill only the controls the agent names, submit and
  clear them. The extension checks the selected document and frame against the
  saved site.
- **Programs.** A program named when the agent asks gets the password on its
  standard input. The agent gets the program's exit status, not its output.
- **The agent's own code.** The agent asks for this kind of approval and you
  see that on the request. `agent-keyring read` then prints the password, so
  it can land in the agent's tool output and chat. Nothing keeps it from the
  agent.
- **Two-factor codes** saved with a login in Apple Passwords. Codes sent by
  SMS or email are not handled.
- **Other machines.** Agents on another Mac, a Linux server or a cloud machine
  on your tailnet can ask too. Their requests go to the relay (see below).
  - **Automatic logins** are served by the relay itself, whether your MacBook
    is awake or shut, to machines you have allowed Automatic logins. Your
    MacBook keeps the relay's copy up to date, including when you re-import a
    changed password, without asking you.
  - **Ask logins** need your approval, with Touch ID on your MacBook or Face
    ID on your iPhone. The login goes sealed to the machine that asked. Your
    paired iPhone keeps its own encrypted copy of your Ask logins, so once that
    copy has synced it can approve and deliver while your MacBook is shut.
    Without a usable copy it can still approve, but your MacBook must be awake
    to deliver.
- **Approving on your iPhone.** An Ask request goes to your iPhone if you
  don't answer on the Mac within your delay, at once if your Mac's screen is
  locked, and at once if your MacBook is not connected to the relay. For agents
  on the MacBook itself, the iPhone's answer goes back to the MacBook, which
  delivers the login.

## Why a relay

Your logins are imported in one place, your MacBook, because Apple Passwords
only exports when you start it. Every other machine where agents work runs
only the `agent-keyring` command and, for browsers, the extension. Those
machines need somewhere that is always on to send requests to, because your
MacBook and iPhone come and go.

The relay is that place. It is one program on an always-on machine on your
tailnet, such as a Mac mini, and it listens only on its tailnet address. It
holds each request until your MacBook or iPhone answers, wakes your iPhone,
and passes on sealed logins it cannot open. It also serves your Automatic
logins itself, so unattended jobs work while your MacBook is shut. Each machine
checks that an Ask approval was signed by your MacBook or iPhone, so the relay
cannot approve one by itself. It holds the key that approves Automatic logins,
so it can approve those for the machines you have allowed.

## What has been tested

The checks completed so far ran on a Mac mini and a Linux server, with dummy
logins and test keys:

- Real Claude Code and Codex agents signing in through the extension, in
  headless Chrome for Testing on a Mac and in desktop Chromium on Linux
  through the relay.
- Programs and remote machines through the real relay.
- Automatic sign-in with the MacBook's side stopped.
- The iPhone's own code approving and delivering through the real relay with
  the Mac disconnected, run on a Mac, not on an iPhone.

Not yet tried on real devices: an Apple Passwords export into this version,
Touch ID and Apple Watch approval, the iPhone app with Face ID and
notifications, an everyday browser profile, and real logins.

## What it does not do

- Fill Safari, or the browsers built into Codex, Claude and T3. The extension
  cannot be installed in them.
- Keep a website signed in or sign it out. That is the agent's browser.
- Sync with Apple Passwords by itself. Apple only allows an export that you
  start, so you export again when logins change.
- Passkeys.
- Protect a password from software that controls the machine receiving it.
  Browser filling and program delivery keep passwords out of the agent's
  conversation and tool output; an agent that sets out to read the browser it
  controls can still do so. The native host sends values only through the extension's private pipe;
  it does not isolate software running as the same user.

## Who can read what

| Where | What it holds | Who can read it |
| --- | --- | --- |
| Your MacBook's Agent Keyring | Every imported login | Whoever controls your MacBook user account |
| The relay | Your Automatic logins, with their two-factor seeds; the name, site, account name and rule of every login; and a list of which machine asked for which login and when | **Anyone who administers the machine running it, including agents you let administer it.** Moving a login off Automatic deletes it from the relay once the relay receives the change, but cannot take back what was already read. Keep a login on Ask if that is not acceptable |
| Your iPhone | Every Ask login, with its two-factor seed, sealed to a key in the phone's Secure Enclave | Only that iPhone, after Face ID. The relay stores the same sealed copy and cannot open it |
| An Ask login on its way to a machine | One login, for one task | Only that machine. The relay passes it on sealed and cannot open it |
| The machine that asked | What it was given | That machine, which can keep it |

Enrolled machines can also list every login's name, site, account name and
rule, without asking.

Rule changes and removing a machine or iPhone take effect on each device as it
receives them; the Machines window shows which devices have confirmed. Neither
takes back a password already delivered, and removing a lost iPhone cannot
erase the copy on it. If it may be in someone else's hands, change those
passwords and set up their two-factor codes again.

If the relay's Mac is also signed in to iCloud Keychain, Apple Passwords on that
Mac already holds every password, with or without Agent Keyring.

## Install

There is no published build of this version yet. Build it from source (you need
Xcode 27, an Apple Developer team and [devenv](https://devenv.sh)):

```sh
git clone https://github.com/joshp123/agent-keyring.git
cd agent-keyring
cp Config/Local.xcconfig.example Config/Local.xcconfig   # add your team ID
devenv shell -- ./script/build_cli.sh
./script/build_and_run.sh --verify
```

Then:

1. Open Agent Keyring. It lives in the menu bar.
2. In Apple Passwords, choose File → Export All Items to App → Agent Keyring.
3. Open Rules and confirm them with Touch ID. Every login starts as Ask.
4. Run `/Applications/AgentKeyring.app/Contents/Helpers/agent-keyring install`.
   It links the `agent-keyring` command and gives Codex and Claude Code the
   bundled instructions.

`install` also registers the browser helper and prints the bundled extension's
folder. Loading that extension once in each Chrome-family profile is a separate
step: open `chrome://extensions`, enable Developer mode, and choose Load
unpacked. The isolated proof and its exact installation are recorded in
[the extension proof](docs/proofs/browser-extension.md).

**Other machines.** Run `agent-keyring-relay` on an always-on machine, listening
on its tailnet address, and pair your MacBook with it in the Machines window. On
each agent machine run `agent-keyring enrol --name NAME --relay HOST:PORT`,
compare the code it prints with the one on your Mac, and approve. Details are
in [docs/implementation/relay.md](docs/implementation/relay.md).

The standalone CLI and its skill are available on macOS and Linux as the Nix
package `agent-keyring` (`nix build .#agent-keyring`). It needs no Mac app. The
skill is in `share/agent-keyring/skills/agent-keyring` inside the package;
`agent-keyring install` links the command and skill for Codex and Claude Code.
Machines managed by Nix should declare those links in their configuration.

Enrolment selects the relay persistently, including on a Mac with the app
installed. An unavailable relay never causes a switch to a local vault. A Mac
using its own imported logins records the selected app and bundle identity;
the presence of a socket alone selects nothing. Explicit connection environment
overrides apply only to that command and do not change the saved selection.

**iPhone.** Build the iPhone app from this repository (it is not in the App
Store) and pair it with the relay from the phone. Compare the code it shows
with the one on your Mac and approve with Touch ID. Your MacBook then sends the
phone its sealed copy of your Ask logins. Notifications need an
Apple push key from your developer account, given to the relay. Without one,
requests appear when you open the app.

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
