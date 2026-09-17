---
name: agent-keyring
description: Acquire saved Apple Passwords credentials into a temporary private buffer with the agent-keyring CLI. Use when a task needs a username, password or saved TOTP code. Reuse the reference until entry succeeds, then explicitly clear it; never expose the value in chat.
metadata:
  written_by: "AI on 2026-09-16 by model gpt-6-astra"
---

# Agent Keyring

Agent Keyring retrieves one saved field into a private temporary buffer and enforces the user's access rule. You own choosing the account, using the value and completing the task.

```sh
agent-keyring find example.com
agent-keyring status
ref=$(agent-keyring acquire password example.com)
# Read into your consumer as needed; reading does not empty the buffer.
agent-keyring clear "$ref"
```

`acquire FIELD SITE` accepts `username`, `password` or `code` (saved TOTP). It authorizes once and prints a reference, never the value. Use `--account NAME` or `--credential UUID` to choose a match returned by `find`; ask if the task does not determine the account. If needed, the executable is `$HOME/.local/bin/agent-keyring`.

`read REF` writes the exact retained value to stdout, without an added newline or another approval. It does not consume the buffer. **This stdout is secret data:** pipe it to a consumer or capture it inside the tool runtime. Do not run `read` as a standalone shell tool call, return its output to the model, use `tee`, or interpolate the value into arguments. Do not trim the value. Use `pipefail` in shell pipelines and catch subprocess failures without dumping their captured stdout. Errors go to stderr with a nonzero exit status.

Keep the reference until the value has been successfully entered. If entry fails, use `read` on that same reference; do not call `acquire` again. Run `clear REF` when done or abandoning the operation, and discard any copies held in runtime variables. Clear is idempotent; reading a cleared reference fails. Buffers have no automatic expiry: explicit cleanup is required. A retained TOTP code can still expire at the website.

Use whatever browser tools are currently available. For a JavaScript browser runtime, for example, capture `read` stdout in a local variable and pass it to the observed input's fill method. Inspect the target after approval or navigation; avoid displaying a populated code field. The model decides how to fill, submit, verify and recover using the current browser API. Keyring has no browser module, selectors or login-session API.

**Allow automatically** needs no approval; **Ask each time** requires one native approval per protected field; **Blocked** refuses access. Wait for a request to complete. Do not retry a denial or change an access rule to make a task work. A failed form submission does not justify another credential request by itself.

`copy` remains available for native clipboard consumers. Codex's browser has a separate clipboard, so macOS Cmd-V is not a substitute for filling its input through the browser tool.

Keyring does not retrieve SMS messages, control browsers or support passkeys. Use the relevant tool for those tasks. A changed password requires refreshing the mirror from Apple Passwords; `status` reports its age.
