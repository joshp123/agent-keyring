---
written_by: ai (Claude Opus 5.5, 2026-10-12)
---

# Agent Keyring

You ask an agent to do something. It needs to sign in. Until now it got stuck, or asked you to paste a password into chat.

With Agent Keyring it carries on. It asks Agent Keyring for the login. Your rule for that login decides: allowed automatically, ask you first, or blocked. If you are asked, you approve on your Mac, or with one tap on your iPhone when you are away. Then Agent Keyring types the login into the sign-in form itself. **The agent never sees your password.**

Your logins stay in Apple Passwords. Agent Keyring keeps an encrypted copy on your Mac.

macOS 26 or later · free and open source · [releases](https://github.com/joshp123/agent-keyring/releases)

**Status:** fill, iPhone approval and signed rules are on `main` and are being proved on real devices before the next release. The latest published release predates them.

## How it works

| Your rule | What happens when an agent asks |
| --- | --- |
| Allow automatically | It signs in without interrupting you. |
| Ask each time | You approve with Touch ID or Apple Watch, or on your iPhone if you are away. One approval covers that login for 30 minutes. |
| Blocked | It refuses. |

- **The browsers agents drive.** Safari, Chrome, Claude's browser pane and Codex's browser: the agent focuses the field and Agent Keyring types the value after checking the page is the real site. Headless browsers sign in through the [agent-browser](https://github.com/vercel-labs/agent-browser) plugin.
- **Agents know what is happening.** While you are being asked, the agent sees lines like "Asked Josh on the Mac at 02:41; will ask on the iPhone at 02:43", so it can tell you what it is waiting for.
- **Agents cannot change your rules.** The rules are signed with a key that needs your Touch ID. Edit them behind its back and nothing is released until you confirm them.

## Set rules with AI

You do not have to sort hundreds of logins yourself. In `Access Rules`, choose `Set Rules with AI`, paste the prompt into any AI and answer its questions about what you trust agents to do, then paste its answer back and review every change before applying it. The prompt contains only sites and current rules, never account names or passwords.

![Setting rules with AI](docs/media/assistant.png)

## Set up

1. Install `AgentKeyring.app` and open it. It lives in the menu bar.
2. In Apple Passwords, choose `File` → `Export All Items to App` → `Agent Keyring`.
3. Run `/Applications/AgentKeyring.app/Contents/Helpers/agent-keyring install`. It teaches Claude Code and Codex how to use it and registers the agent-browser plugin.
4. To approve from your iPhone, build the iPhone app from this repository (there is no App Store version yet), choose `Add iPhone` on the Mac and scan the code.

Apple has no silent export, so Agent Keyring reminds you when its copy is more than a week old. Repeat step 2 to update it.

## For agents

`agent-keyring --help` explains everything; the installed skill has the details. In short:

```sh
agent-keyring fill username example.com    # focus the field first
agent-keyring fill password example.com
agent-keyring fill code example.com        # two-factor code
agent-keyring sync example.com             # the site rejected the login
```

Programs that need a value get it by pipe, never on screen: `acquire` returns a reference, `read` pipes the value and `clear` removes it.

## Security

- Passwords never go to the agent through `fill` or the agent-browser plugin. `fill` checks the screen is unlocked, the page address belongs to the saved site, and the focused field is the right kind before typing.
- Approvals from the iPhone are signed by a key in its Secure Enclave and checked by the Mac against its own copy of the request. Pairing needs a code you type and Touch ID.
- The encrypted copy and the signed rules stay on your Mac. Requests to the iPhone travel through your private iCloud database, with site and account encrypted.
- `Allow automatically` trusts any program running as you while your Mac is unlocked.
- Passkeys are not supported yet.

Every permission Agent Keyring asks for, and why, is in [docs/permissions.md](docs/permissions.md).

## Build from source

You need Xcode 27 and an Apple Developer team.

```sh
git clone https://github.com/joshp123/agent-keyring.git
cd agent-keyring
cp Config/Local.xcconfig.example Config/Local.xcconfig
./script/build_and_run.sh --verify
swift test --package-path AgentKeyringPackage
```

## Licence

MIT. See [LICENSE](LICENSE).
