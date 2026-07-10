---
name: agent-keyring
description: Use the local Agent Keyring app to resolve and use Apple Passwords usernames, passwords and TOTP codes without exposing secrets in agent output. Use when a task reaches a login, sign-in, verification-code or credential prompt in Safari, Codex's built-in browser, Chrome or another local app; when an existing Apple Passwords credential may let the task continue; or when checking or refreshing the encrypted mirror. Passkeys are not supported yet.
---

# Agent Keyring

Use `agent-keyring` before asking the user for credentials. It asks the signed app to copy one field to the macOS pasteboard. Command output contains only safe metadata and receipts. A password or verification-code request normally displays a native Touch ID or Apple Watch prompt naming the account and destination. The user's saved access rule may allow or block the request instead.

## Resolve the credential

1. Read the exact current page URL from the browser or app context.
2. Check the mirror when useful:

   ```sh
   agent-keyring status
   ```

3. Resolve candidates without requesting a secret:

   ```sh
   agent-keyring resolve --url 'https://example.com/login'
   ```

4. If one candidate matches, copy the required field and paste it into the intended control:

   ```sh
   agent-keyring copy --url 'https://example.com/login' --field username
   agent-keyring copy --url 'https://example.com/login' --field password
   agent-keyring copy --url 'https://example.com/login' --field totp
   ```

   Use browser or Computer Use controls to press Cmd-V. Never inspect the pasteboard value.

5. If several candidates remain, use a known account identity:

   ```sh
   agent-keyring resolve --url 'https://example.com/login' --username 'known-account'
   ```

   Otherwise use a candidate UUID returned by `resolve`:

   ```sh
   agent-keyring copy --url 'https://example.com/login' --candidate UUID --field password
   ```

   Choose only from visible task context or known user identity. If that does not determine the account, ask one short account-choice question. Do not guess.

## Guardrails

- Never run `pbpaste`, print the clipboard, inspect Agent Keyring's encrypted files, or add a secret-bearing `get` command.
- Never put a password, TOTP seed or TOTP code in stdout, stderr, arguments, environment variables, logs or chat.
- Bind every copy to the actual HTTPS page URL. Do not bypass `insecure_origin` failures.
- Treat an `ambiguous` response as a required choice, not a reason to take the first result.
- Paste promptly. Agent Keyring clears its clipboard value after 30 seconds if nothing else has replaced it.
- If a native prompt appears, wait for the user to approve it. Treat `authorization_denied` as final for that request. Do not retry or work around it.
- Treat `policy_denied` as final. Do not ask for the same credential through another route.
- A failed login may mean Apple Passwords changed after the last mirror refresh. Do not retry repeatedly. Report the mirror age and refresh through Agent Keyring and Apple Passwords.
- Passkeys remain in Apple Passwords and normally require a human-present Apple flow.

If `agent-keyring` is not on `PATH`, use `$HOME/.local/bin/agent-keyring`.
