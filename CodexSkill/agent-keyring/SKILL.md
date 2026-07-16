---
name: agent-keyring
description: Use the local Agent Keyring app to resolve and use Apple Passwords usernames, passwords and TOTP codes without exposing secrets in agent output. Use when a task reaches a login, sign-in, verification-code or credential prompt in Safari, Codex's built-in browser, Chrome or another local app; when an existing Apple Passwords credential may let the task continue; or when checking or refreshing the encrypted mirror. Passkeys are not supported yet.
written_by: ai
---

# Agent Keyring

Use `agent-keyring` before asking the user for credentials. It asks the signed app to copy one field to the macOS pasteboard. Command output contains only safe metadata and receipts. A password or verification-code request normally displays a native Touch ID or Apple Watch prompt naming the account and destination. The user's saved access rule may allow or block the request instead.

## Use a login

1. Read the exact current page URL from the browser or app context.
2. Find matching logins without requesting a secret:

   ```sh
   agent-keyring find 'https://example.com/login'
   ```

3. Copy the required field and paste it into the intended control:

   ```sh
   agent-keyring copy username 'https://example.com/login'
   agent-keyring copy password 'https://example.com/login'
   agent-keyring copy code 'https://example.com/login'
   ```

   Use browser or Computer Use controls to press Cmd-V. Never inspect the pasteboard value.

4. If several logins match, use a known account identity:

   ```sh
   agent-keyring copy password 'https://example.com/login' --account 'known-account'
   ```

   If two entries have the same account identity, use the credential ID shown by `find`:

   ```sh
   agent-keyring copy password 'https://example.com/login' --credential UUID
   ```

   Choose only from visible task context or known user identity. If that does not determine the account, ask one short account-choice question. Do not guess.

## Guardrails

- Never run `pbpaste`, print the clipboard, inspect Agent Keyring's encrypted files, or add a secret-bearing `get` command.
- Never put a password, TOTP seed or TOTP code in stdout, stderr, arguments, environment variables, logs or chat.
- Bind every copy to the actual HTTPS page URL. Do not bypass an insecure-page refusal.
- If several logins match, choose from visible task context or ask the user. Never take the first one arbitrarily.
- Paste promptly. Agent Keyring clears its clipboard value after 30 seconds if nothing else has replaced it.
- If a native prompt appears, wait for the user to approve it. If they do not, do not retry or work around it.
- If Agent Keyring says access is blocked, do not ask for the same credential through another route.
- A failed login may mean Apple Passwords changed after the last mirror refresh. Do not retry repeatedly. Report the mirror age and refresh through Agent Keyring and Apple Passwords.
- Passkeys remain in Apple Passwords and normally require a human-present Apple flow.

If `agent-keyring` is not on `PATH`, use `$HOME/.local/bin/agent-keyring`.
