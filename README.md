# Agent Keyring

Agent Keyring lets your AI agents sign in to websites with the logins you keep
in Apple Passwords, with your approval, and without the password passing
through the agent's chat.

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
- **Google Chrome, Chrome for Testing and Chromium on macOS and Linux.** Agent
  Keyring uses the browser's existing local debugging endpoint on the same
  machine as the agent. It checks which process owns the endpoint and identifies
  its browser installation, checks the page belongs to the saved site, fills
  only the fields the agent names, submits, and clears what it typed. It does
  not launch or restart browsers or change their profiles.
- **Programs.** A program named when the agent asks gets the password on its
  standard input. The agent gets the program's exit status, not its output.
- **Other browsers, from the agent's own code.** For a browser with no
  debugging port, the agent can ask for the value to be given to its own code,
  which types it into the page. You are told this when you approve. The value
  then sits in the agent's process, so this route keeps the password out of
  the chat, not out of the agent's reach.
- **Two-factor codes** saved with a login in Apple Passwords. Codes sent by
  SMS or email are not handled.
- **Other machines.** Agents on another Mac, a Linux server or a cloud machine
  on your tailnet can ask too. Their requests go to a small relay that runs on
  an always-on Mac, such as a Mac mini.
  - **Automatic logins** are served by the relay itself, whether your MacBook
    is awake or shut, to machines you have allowed Automatic logins. Your
    MacBook keeps the relay's copy up to date, including when you re-import a
    changed password, without asking you.
  - **Ask logins** need your approval. Your MacBook delivers them, sealed to
    the machine that asked, so it must be awake.
- **Approving on your iPhone.** If you don't answer on the Mac within your
  delay, or your Mac's screen is locked, an Ask request goes to your iPhone.
  You approve with Face ID; your MacBook delivers the login, so it must be
  awake.

## What it does not do

- Fill Safari or the closed browser tools in agent apps, except through the
  agent's-own-code route above where the host supports it.
- Keep a website signed in or sign it out. That is the agent's browser.
- Deliver Ask logins while your MacBook is asleep or shut. Delivering them
  from the iPhone is designed but not built yet.
- Sync with Apple Passwords by itself. Apple only allows an export that you
  start, so you export again when logins change.
- Passkeys.
- Protect a password from software that controls the machine receiving it.
  Agent Keyring keeps passwords out of the agent's conversation and tool
  output; an agent that sets out to read the browser it controls can still do
  so. Endpoint checks reject a fake debugging server; they do not authenticate
  the publisher of an ad-hoc or unpacked browser build or isolate software
  running as the same user.

## Who can read what

| Where | What it holds | Who can read it |
| --- | --- | --- |
| Your MacBook's Agent Keyring | Every imported login | Whoever controls your MacBook user account |
| The relay | Your Automatic logins, with their two-factor seeds, and a list of which machine asked for which login and when | **Anyone who administers the Mac running it, including agents you let administer it.** Moving a login off Automatic deletes it from the relay but cannot take back what was already read. Keep a login on Ask if that is not acceptable |
| An Ask login on its way to a machine | One login, for one task | Only that machine. The relay passes it on sealed and cannot open it |
| The machine that asked | What it was given | That machine, which can keep it |

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

**Other machines.** Run `agent-keyring-relay` on an always-on Mac, listening on
its tailnet address, and pair your MacBook with it in the Machines window. On
each agent machine run `agent-keyring enrol --name NAME --relay HOST:PORT`,
compare the code it prints with the one on your Mac, and approve. Details are
in [docs/implementation/relay.md](docs/implementation/relay.md).

**iPhone.** Build the iPhone app from this repository (it is not in the App
Store) and pair it with the relay from the phone. Compare the code it shows
with the one on your Mac and approve with Touch ID. Notifications need an
Apple push key from your developer account, given to the relay. Without one,
requests appear when you open the app.

## For agents

`agent-keyring skill` prints the instructions agents follow, and
`agent-keyring --help` lists every command. A sign-in looks like this:

```sh
agent-keyring find example.com
lease=$(agent-keyring lease LOGIN_ID --task "$task" --reason "What the user asked for")
agent-keyring fill "$lease" --browser "$endpoint" --tab "$tab" \
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
The prompt contains sites and current rules, never account names or passwords,
and you review every change before it applies.

## Licence

MIT. See [LICENSE](LICENSE).
