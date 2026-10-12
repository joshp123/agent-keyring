---
name: agent-keyring
description: "Sign in to websites and use passwords, one-time codes and API keys from the user's Apple Passwords without ever seeing them. Use whenever a task needs a login, a password, a two-factor code or a saved secret. Do not ask the user to type or paste passwords."
metadata:
  written_by: "AI on 2026-10-12 by model Claude Opus 5.5"
---

# Agent Keyring

Agent Keyring holds the user's saved logins. You ask for a login; their rule for it decides, or they approve on their Mac or iPhone. Agent Keyring then puts the value where it is needed. You never see it, never print it and never ask the user for it.

## Sign in to a website in a visible browser

This works in Safari, Chrome, Claude's built-in browser pane, Claude in Chrome and Codex's browser.

1. Focus the username field, then run `agent-keyring fill username example.com`.
2. Focus the password field, then run `agent-keyring fill password example.com`.
3. Click the sign-in button yourself. Agent Keyring never presses Return.
4. If a two-factor code is asked for, focus that field and run `agent-keyring fill code example.com`.

Use the site the login is saved under. The page you are on must be that site or one of its subdomains.

## Sign in headlessly with agent-browser

```sh
agent-browser auth login example --credential-provider agent-keyring --item "example.com"
```

To choose an account, add it after the site: `--item "example.com jane@example.com"`. If this returns "Waiting for … approval", wait until the user approves, then run the same command again; it fills from the approval.

## Give a secret to a program

Pipe it straight into the program. Never let `read` output reach your own tool output.

```sh
ref=$(agent-keyring acquire password example.com)
agent-keyring read "$ref" | some-command --password-stdin
agent-keyring clear "$ref"
```

Values expire after 5 minutes. Clear them when you are done.

## Approvals take time

A command may wait up to 10 minutes while the user is asked on their Mac or iPhone. It prints plain status lines, such as "Asked … on his Mac at 02:41". Tell the user what you are waiting for, in your own words. One approval covers that login for 30 minutes, so later fills do not ask again.

## When something goes wrong

The exit code says what happened; `agent-keyring --help` lists every code. The ones that need you to act:

| Code | Meaning | What to do |
| --- | --- | --- |
| 2 | The user declined | Stop and ask them what they want. |
| 3 | No answer in 10 minutes | Tell the user, then retry when they are back. |
| 7 | The access rules need confirming | Ask the user to confirm the rules in Agent Keyring. |
| 8 | Wrong or no field focused | Focus the right field and run fill again. |
| 9 | The page does not match the saved site | Check you are on the real site. Do not work around this. |
| 10 | This browser's address cannot be read | Use agent-browser instead. |
| 11 | Accessibility permission is missing | Ask the user to grant Agent Keyring Accessibility. |
| 13 | The page or field changed | Focus the field again and retry. |

If a site rejects a login that Agent Keyring filled, run `agent-keyring sync example.com`, then tell the user that their saved password may be out of date.

## Finding the right login

`agent-keyring find example.com` lists matching logins and their accounts without revealing any secret. Pass `--account` to `fill` or `acquire` when several match.
