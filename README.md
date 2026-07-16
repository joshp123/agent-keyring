---
written_by: ai
---

# Agent Keyring

Tell Codex what you want. Agent Keyring handles the login.

When Codex reaches a password in Safari or its built-in browser, Agent Keyring finds the matching Apple Passwords credential and follows your rule:

| Rule | What happens |
| --- | --- |
| Allow automatically | Codex continues without interrupting you. |
| Ask each time | Approve the exact website and account on Apple Watch or Touch ID. |
| Blocked | Agent Keyring refuses the request. |

Apple Passwords remains your source of truth. Agent Keyring uses Apple's credential exchange flow, Keychain and LocalAuthentication. Passwords and codes never appear in chat or command output.

[Download the signed and notarised app](https://github.com/joshp123/agent-keyring/releases/latest) · macOS 26 or later · free and open source

[![Agent Keyring: automatic, approved or blocked credential access for Codex](docs/media/agent-keyring-demo.gif)](docs/media/agent-keyring-demo.mp4)

The demo uses synthetic accounts. Product screens are real native window captures. The macOS Watch prompt is genuine and captured separately; it does not claim to show a completed Watch approval.

## Work out your rules with AI

You do not need to classify every credential yourself.

1. Open `When Agents Can Sign In`, select `Work Out Your Rules with AI` and copy the prompt.
2. Read the copied text, then paste it into ChatGPT, Claude or another AI. It helps you describe what you trust local agents to access unattended, what should ask you first and what they should never use.
3. Copy the AI's entire final response and paste it back into Agent Keyring.
4. Select `Review Proposal`. Agent Keyring checks every credential ID and shows every proposed change before you can apply it.

The copied text contains only opaque credential IDs, sites and current rules. It never contains account names, usernames, passwords, verification codes or TOTP seeds.

![Agent Keyring's copy-and-paste AI policy assistant](docs/media/assistant.png)

## Approval on Apple Watch

For credentials set to `Ask each time`, Agent Keyring shows the requested website, account and field before macOS asks for approval. One Apple Watch or Touch ID approval releases one requested field.

![Agent Keyring beside the native macOS Apple Watch approval prompt](docs/media/approval-watch.png)

## Set up once

1. Download the ZIP, move `AgentKeyring.app` to Applications and open it. It appears as a key in the menu bar.
2. Ask Codex to run:

   ```text
   Set up Agent Keyring for me by running:
   /Applications/AgentKeyring.app/Contents/Helpers/agent-keyring install
   ```

3. From the menu-bar key, choose `Open Agent Keyring`, then select `Allow imports from Passwords`. In Apple Passwords, choose `File` → `Export All Items to App` → `Agent Keyring`, then approve once.

That is it. Ask Codex normally. You do not need to restart Codex.

Repeat the Apple Passwords export to import new, changed and removed credentials into Agent Keyring’s encrypted copy. Apple does not provide silent or incremental password export.

## Security boundaries

- the local mirror is encrypted with AES-GCM; its key is stored in your login Keychain
- `Allow automatically` trusts every process running as your unlocked macOS user
- approved secrets use the shared macOS pasteboard; another process in your user session could read them before Agent Keyring clears its value after 30 seconds
- the agent supplies the destination URL because browsers do not give Agent Keyring an attested active-tab origin
- passkeys are not supported yet
- Apple may omit shared credentials, Sign in with Apple records and items without passwords
- a changed password is not available to agents until you import from Apple Passwords again

Sparkle checks this repository for signed updates. Automatic installation is off.

## Build from source

You need Xcode 27 and an Apple Developer team with the AutoFill Credential Provider capability.

```sh
git clone https://github.com/joshp123/agent-keyring.git
cd agent-keyring
cp Config/Local.xcconfig.example Config/Local.xcconfig
./script/build_and_run.sh --verify
```

Run tests with `swift test --package-path AgentKeyringPackage`.

## Licence

MIT. See [LICENSE](LICENSE).
