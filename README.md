---
written_by: ai
---

# Agent Keyring

Agent Keyring gives local AI agents controlled access to credentials from Apple Passwords. Apple Passwords remains the source of truth.

The app keeps an encrypted local mirror of passwords and TOTP seeds. Its command-line tool copies one field to the macOS pasteboard without printing the value.

Passkeys are not supported yet.

## What works

- Apple Passwords exports directly to Agent Keyring through macOS Credential Exchange
- one Touch ID or Apple Watch approval refreshes the full local mirror
- AES-GCM encrypts each immutable snapshot, using a key stored in the login Keychain
- later exports report added, changed, removed and skipped counts
- the `agent-keyring` command resolves credentials by HTTPS origin
- passwords and verification codes use one native approval by default
- the app clears its own pasteboard value after 30 seconds
- a bundled Codex skill handles login prompts in Safari and Codex's browser

## Access rules

Select Manage access in the app to search, sort and change rules for mirrored credentials.

Each credential has one of 3 rules:

- Ask each time uses Touch ID or Apple Watch before releasing a password or verification code
- Allow automatically skips native approval for that credential
- Block refuses every copy request for that credential

New credentials use Ask each time. Rules use stable credential IDs, so they survive a full refresh. The rule file contains IDs and policy values only.

Allow automatically trusts any local process running as your macOS user that can call the broker. Agent Keyring does not yet authenticate individual agents.

## Build and install

You need macOS 26, Xcode 27 and an Apple Developer Program team. The team must support the AutoFill Credential Provider entitlement.

1. Copy the local signing template.

   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. Set your bundle ID prefix and Apple Developer team ID in `Config/Local.xcconfig`.

3. Build, sign, install and verify the app.

   ```sh
   ./script/build_and_run.sh --verify
   ```

The script installs these local components:

- `/Applications/AgentKeyring.app`
- `~/.local/bin/agent-keyring`
- `~/.codex/skills/agent-keyring`

## Refresh from Apple Passwords

1. Launch Agent Keyring and enable its credential-provider extension once.
2. Open Apple Passwords.
3. Select File, then Export All Items to App.
4. Select Agent Keyring and approve the export once.

Agent Keyring treats every received export as a complete snapshot. Do not use Export Selected Items to App for a normal refresh.

Apple excludes some records before Agent Keyring receives them. These can include Sign in with Apple entries and credentials shared by someone else. Agent Keyring also skips passkeys, records without a usable password and unsupported credential types.

Apple does not provide silent background export or an incremental change feed. A scheduled check can detect an old mirror, but it cannot identify unseen changes inside Apple Passwords.

## Agent interface

All commands return JSON. Secret values never appear in command output.

```sh
agent-keyring status
agent-keyring resolve --url 'https://example.com/login'
agent-keyring copy --url 'https://example.com/login' --field username
agent-keyring copy --url 'https://example.com/login' --field password
agent-keyring copy --url 'https://example.com/login' --field totp
```

If a site has several accounts, `resolve` returns safe candidate metadata. Narrow the result with `--username` or pass a returned UUID through `--candidate`. Agent Keyring does not guess between ambiguous accounts.

`copy` binds the request to an HTTPS origin and a live requesting process. It then places one value on the pasteboard. For an Ask each time rule, the app shows the website, account and access type beside the native approval prompt. The user approves once.

## Security limits

- the agent states the destination URL; Safari and Codex do not provide an attested active-tab origin
- browser use relies on a short-lived pasteboard handoff
- the local broker protects against stale, changed and abandoned requests
- access rules apply per credential, not per agent or calling application
- anyone who controls your unlocked macOS user account is inside the current trust boundary
- passkeys remain in Apple Passwords and require Apple's normal flow

## Licence

Agent Keyring uses the MIT Licence. See `LICENSE`.
