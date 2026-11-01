---
written_by: AI (Claude Opus 5.5, 2026-11-01)
status: design for review; no code yet
depends_on: 0004 (leases), 0005 (relay), 0008 (copies)
replaces: the Chromium debugging-port receiver in 0004
---

# RFC 0009: filling sign-in forms in the browsers agents already use

## The problem

Josh, 30 October: "agents struggle with filling credentials properly", and
"we wanna kinda copy 1password's best in class for agentic stuff". On 1
November, about today's filler: it only reaches a Chrome started with a
debugging port, "so it's fucking useless since we need to install random chrome
browsers everywhere", and it has to "work in claude AND codex AND other 3rd
party browsers AND via the command line if the browsers aren't present".

Today's filler connects to Chrome's debugging port. Google stopped branded
Chrome from opening that port on the normal profile in Chrome 136, so it only
works in a Chrome an agent launched separately. Josh's real Chrome, his Safari,
and the browsers Claude and Codex drive are out of reach.

## How 1Password does it

1Password's agent sign-in uses its own browser extension inside the real
browser (support.1password.com/1password-claude-security/):

- The agent asks; Josh approves in the 1Password app.
- The 1Password app sends the login to its own extension in that browser over
  an encrypted local channel.
- The extension checks the page matches the saved site, fills, submits and
  clears the fields if the submit fails. The agent gets a result, never the
  value.
- Claude's side pauses its view of the page during the fill. That pause is a
  1Password and Anthropic partnership feature.

The shape to copy is the first three: an extension in the browser does the
filling, and the agent only gets a result. The partner pause is not available
to us.

## The design

**An Agent Keyring browser extension does the filling.** It runs in the
browser Josh or the agent is already using. The agent keeps using the same
command:

```sh
agent-keyring fill "$lease" [--username CSS] [--password CSS] [--code CSS] [--submit CSS]
```

1. The CLI passes the request to the extension's native messaging host: a
   small helper the browser starts for the extension, which is the same
   `agent-keyring` binary.
2. The host gets the value from Agent Keyring (the Mac app, or the relay as in
   RFC 0005) under the lease, exactly as today.
3. It hands the value to the extension over the browser's native messaging
   pipe. Nothing passes through the CLI's output or the agent's chat.
4. The extension finds the tab: the one tab on the lease's saved site. If
   there are several, the agent passes `--url`. It reads the page's real
   address from the browser itself, so it cannot be fooled about which site it
   is on.
5. It fills the fields the agent named. Without selectors it uses the page's
   own `autocomplete` markings (username, current-password, one-time-code).
   It submits, clears what it typed if the page doesn't move on, and returns
   submitted, uncertain or a reason it refused.

The lease, approvals, 30-minute limit, retries and receiver records are
unchanged (RFC 0004). The extension plus its host is the "receiver".

**Without a browser, the CLI does the job.** Programs get the value on stdin
with `exec`; the agent's own code gets it with `read` (RFC 0004). Those stay
as they are.

## Where it works

| Where | How | Status |
| --- | --- | --- |
| Josh's Google Chrome, and Brave, Edge, Arc | The Chrome extension | Build |
| Claude Code and Claude in Chrome | Claude in Chrome drives Josh's real Chrome, where our extension also runs; Claude Code runs `agent-keyring fill` from its shell | Build |
| Codex CLI | Its shell runs `agent-keyring fill` against whichever browser has the extension | Build |
| Codex app, Chrome surface | Codex can drive Josh's real Chrome through its Chrome plugin; our extension fills there | Build |
| Safari | A Safari web extension inside the Agent Keyring Mac app. Safari only lets an extension talk to its own containing app, which here is Agent Keyring itself | Build |
| Agent-launched Chromium and Chrome for Testing, on Mac or Linux | The same Chrome extension, loaded with `--load-extension`, which these builds still accept | Build |
| Linux desktop Chrome or Chromium | The same extension and host; the host talks to the relay as an enrolled machine | Build |
| No browser | `exec` and `read`, as now | Exists |
| Codex app's in-app browser | None. It takes credentials only from Josh typing into ChatGPT's own form or from its built-in 1Password adapter. It accepts no other extension and no other password manager | **Gap**: use the Chrome surface instead, or `read` from the agent's own code |
| T3 Code's preview | None. Its typing tool takes literal text only | **Gap**: needs T3 to accept a secret reference |
| Claude Desktop's 1Password integration | Works only with 1Password | Not ours to use |

## What it protects, and what it doesn't

- **Protected:** the password never appears in the agent's commands, tool
  output or chat. The extension fills only on the lease's saved site, checked
  by the browser.
- **Not protected:** the password is in the page between filling and
  submitting. An agent driving the same browser could read the field in that
  moment if it set out to. 1Password relies on a partner pause for this; we
  have no such pause in Claude or Codex. The extension submits at once and
  clears on failure to keep that moment short.
- The extension needs permission to read and change all websites, because it
  must fill on any saved site. 1Password's extension has the same permission.

## What is thrown away

- The debugging-port filler and its Google Chrome signature check.
- `agent-keyring fields` and the `--browser` and `--tab` flags. The agent uses
  its own browser tools to look at the page, and the extension finds the tab
  by site.
- The `ChromiumTarget` in the contract, replaced by an optional URL.

## Installing it

- **Chrome-family browsers:** either load the extension unpacked from
  `chrome://extensions` with Developer mode on, once per browser profile, or
  publish it as an unlisted Chrome Web Store item, which installs normally and
  updates itself. Branded Chrome no longer accepts `--load-extension`.
- **Safari:** it ships inside the Mac app; Josh turns it on once in Safari's
  settings.
- **Native messaging host:** `agent-keyring install` writes the host's small
  manifest file into each browser's NativeMessagingHosts folder.

## Build slices

| Slice | What | Done when |
| --- | --- | --- |
| F1 | Chrome extension and native host, with `fill` routed to it | Claude Code fills a test sign-in in Josh's own Chrome with one approval, and the value appears in no tool output |
| F2 | Remove the debugging-port filler, `fields` and the old flags; update the skill | The skill describes one way to fill |
| F3 | Safari web extension in the Mac app | The same test sign-in works in Safari |
| F4 | Linux host through the relay | A Linux machine with desktop Chromium fills a test sign-in |

## Device proofs

With test logins only: Claude in Chrome, Codex CLI and Codex's Chrome surface
each complete a two-step sign-in in Josh's real Chrome; Safari does the same;
an agent-launched Chromium on Linux does the same. In each case the password
and code appear in no transcript.

## Josh's decision

How the Chrome extension is installed: unpacked in Developer mode on each
browser profile (free, manual, no automatic updates), or as an unlisted Chrome
Web Store item. The Web Store needs Google's one-time developer registration fee (US$5) and
Google's review of each version.
