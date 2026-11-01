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

**An Agent Keyring browser extension does the filling**, in the browser Josh or
the agent is already using. Agents drive it with three commands, all from a
shell, so it works for any agent that can run a command, whatever browser tool
it also has:

```sh
agent-keyring tabs                       # browsers and tabs with the extension; no secrets
agent-keyring fields --tab TAB           # the tab's visible fields and buttons, with selectors; no values
agent-keyring fill "$lease" --tab TAB \
  --username CSS --password CSS --submit CSS     # or --code CSS for a two-factor step
```

The model reads `fields` (or its own browser tools) and chooses the fields and
the submit control. Code only fills what it was told to.

### How the command reaches the browser

Chrome starts the extension's native messaging host and owns its pipe, so a
separate command cannot write to that pipe. Instead:

1. When a browser profile with the extension starts, the extension opens a
   long-lived native messaging port. Chrome starts the host, the same
   `agent-keyring` binary, and keeps it running while the port is open; an
   open port also keeps the extension's background worker alive.
2. The host listens on its own Unix socket in Agent Keyring's private state
   directory, readable only by Josh's user. The socket is named by a random ID
   the extension keeps for that browser profile, so each profile has its own
   host and socket.
3. `tabs` connects to every socket in that directory. Each host answers with
   its browser's name, its profile ID and its open tabs. A socket that doesn't
   answer belongs to a browser that has quit, and is deleted.
4. `fill` and `fields` connect to the socket named in the tab target.

A browser restart starts a new host on the same profile ID; tab IDs change, so
the agent runs `tabs` again. Several profiles, or several browsers, are simply
several sockets.

**Safari** works the same way to the agent, but Safari lets an extension talk
only to its own containing app, so the Agent Keyring Mac app plays the host:
the Safari extension keeps a port open to the app, and the app answers `tabs`,
`fields` and `fill` for Safari tabs on its existing local socket.

### Which tab, and what is checked

- A tab target is opaque: browser profile, tab and the document it showed when
  listed. `tabs` lists each with its URL and title. Two agents working at once
  each use their own target.
- If the agent passes no target, `fill` uses the one tab on the lease's saved
  site; if there is more than one, it refuses and lists them.
- Just before filling, the extension checks that the tab still shows the same
  document, that the frame holding the fields is on the lease's saved site
  (read from the browser, not from the page), and that each selector matches
  exactly one visible field. Anything else is refused without filling.

### The fill

1. The host gets the value from Agent Keyring under the lease (the Mac app, or
   the relay as in RFC 0005). The host is the receiver; the CLI never sees the
   value.
2. The host hands it to the extension over its pipe. The extension fills,
   submits, clears what it typed if the page doesn't move on, and returns
   submitted, uncertain or the reason it refused.

The lease, approvals, 30-minute limit and retry records are unchanged (RFC
0004). The host keeps the retry records.

**Without a browser, the CLI does the job.** Programs get the value on stdin
with `exec` (RFC 0004).

## Where it works

Nothing below is proved yet except where it says so. Each row is proved by the
slice that builds it.

| Where | How |
| --- | --- |
| Josh's Google Chrome, and Brave, Edge, Arc | The Chrome extension |
| Claude Code | Its shell runs `tabs`, `fields`, `fill` against Josh's Chrome or Safari |
| Claude in Chrome | It drives Josh's real Chrome, where our extension also runs; the fill is triggered from Claude Code's shell |
| Codex CLI, and the Codex app with its shell | The same shell commands, against Josh's Chrome or Safari |
| Safari | A Safari web extension inside the Mac app |
| Agent-launched Chromium and Chrome for Testing, Mac or Linux | The same extension, loaded with `--load-extension`, which these builds still accept |
| Linux desktop Chrome or Chromium | The same extension and host; the host talks to the relay |
| No browser | `exec`, as now (proved) |

**Gaps, exactly:**

- **Codex app's in-app browser.** It accepts no other extension. Its sign-in
  feature takes credentials only from Josh typing into ChatGPT's own form or
  from its built-in 1Password support, according to the installed plugin's
  documentation and code. There is no supported way to put a password into it
  without the agent handling it. Agents sign in through Josh's Chrome or Safari
  instead.
- **T3 Code's preview.** Its typing tool accepts literal text only.
- **Claude Desktop's 1Password integration** is for 1Password only.

The earlier "`read` from the agent's own code" fallback for these is dropped:
no host offers a supported way to pass that output into its browser privately.

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

- The debugging-port filler, its Google Chrome signature check, and the
  `--browser` endpoint flag.
- The `ChromiumTarget` in the contract, replaced by the opaque tab target.
- `fields` and `--tab` stay, now answered by the extension.

## Installing it

- **Chrome-family browsers:** either load the extension unpacked from
  `chrome://extensions` with Developer mode on, once per browser profile, or
  publish it as an unlisted Chrome Web Store item, which installs normally and
  updates itself. Branded Chrome no longer accepts `--load-extension`.
- **Safari:** it ships inside the Mac app; Josh turns it on once in Safari's
  settings.
- **Native messaging host:** `agent-keyring install` writes the host's small
  manifest file into each browser's NativeMessagingHosts folder. The manifest
  names our extension's ID, so no other extension can start the host.

## Build slices

| Slice | What | Done when |
| --- | --- | --- |
| F1 | Chrome extension, native host, socket per profile, `tabs`, `fields`, `fill` | The proof below passes |
| F2 | Remove the debugging-port filler and the old flags; update the skill | The skill describes one way to fill |
| F3 | Safari web extension, hosted by the Mac app | The proof below passes in Safari |
| F4 | Linux host through the relay | The proof below passes on a Linux machine with desktop Chromium |

## The first proof

Isolated, with test logins and nothing installed globally: Chrome for Testing
with its own profile, the extension loaded with `--load-extension`, and the
host's manifest in that profile's own NativeMessagingHosts folder.

- A real agent (Claude Code, then Codex CLI) gets one approval, lists tabs,
  targets its own tab, and completes a password step and a two-factor step.
- It retries a step and gets the recorded result, with no second approval.
- With two identical sign-in tabs open, an untargeted `fill` refuses and the
  targeted one fills the right tab.
- After a browser restart, the agent runs `tabs` again and carries on under the
  same lease.
- The password and code appear in no transcript or tool output.

Then the same in Josh's own Chrome with Claude in Chrome, and in Safari.

## Josh's decision

How the Chrome extension is installed: unpacked in Developer mode on each
browser profile (free, manual, no automatic updates), or as an unlisted Chrome
Web Store item. The Web Store needs Google's one-time developer registration fee (US$5) and
Google's review of each version.
