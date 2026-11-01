<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Browser extension: isolated first proof

Real Claude Code and Codex CLI agents signed in through the extension with a
shell and the bundled skill. Each used one browser lease for password, saved
TOTP, retries and an injected browser restart, reached `/account`, and released
the lease. Neither wrote a Chrome client. The dummy password, TOTP seed and
codes were absent from their transcripts and CLI output.

This proves RFC 0009's first isolated slice. It used Chrome for Testing
156.0.8078.80, mac-arm64, headless on the Mac mini running macOS 26.6.2. The
authority was `script/lease_fixture`: it issued one stand-in grant per task,
without a real approval panel or Touch ID. No real logins, installed vault,
ordinary browser profile, global host registration or MacBook runtime was used.

## What ran

The extension has no popup, settings page or other visual interface. Chrome
starts the same `agent-keyring` executable as its native messaging host. The
host exposes one owner-only Unix socket per browser profile. `tabs` and `fields`
return metadata through it; `fill` receives only a result. Credential values
travel from the authority to the host and through Chrome's native pipe to the
extension, never through the CLI's request or response.

The content script runs in Chrome's isolated extension world. Document IDs and
frame URLs come from Chrome, and filling checks the current document, saved
site, selectors, field types and common form. This does not isolate a password
from software controlling that browser or the same user account, and it does
not pause Claude's or Codex's observation of the page.

The native host is `com.agentkeyring.browser`; the extension ID is
`mkdkcfdlllhmbiopfomejjhnfhfmphlk`. Its manifest contains the public key that
keeps that ID stable. CLI-to-host messages use protobuf. Chrome's native
messaging boundary uses its required length-prefixed JSON.

## System checks

`script/prove_cli.py` retains the program and agent-process workflows and runs
`script/prove_fields.py` for the extension path:

- With no authority running, `tabs` lists the real page and `fields` lists
  visible inputs and buttons. Already populated fields remain unchanged and
  their values are absent from output.
- Two identical sign-in tabs cause an untargeted fill to refuse. An explicit
  target fills only the selected tab. Retrying that exact action after
  navigation returns its receipt and adds no password POST. Reusing an explicit
  operation key with changed inputs is refused.
- Browser and helper restart with the same disposable profile. The profile ID
  persists, old document targets are refused, and fresh targets finish password
  and saved TOTP using the existing lease. The restarted browser has no
  debugging port.
- A form that stays on the page has its inputs cleared. A retry does not click
  again; an inspected deliberate `--again` does. An unsuitable field is refused.
- `fields` identifies a visible frame on a different loopback origin. Filling
  its target with the parent's lease is refused, with zero POSTs at that origin.
- Killing the helper while a submit handler is running leaves a pending
  receipt. The browser finishes the submission, the extension reconnects, and
  the retry reports uncertainty without submitting twice.
- Programs receive the password on stdin. Echoed child output is suppressed,
  exit status is retained, retries do not start a second process, and a killed
  receiver leaves an uncertain receipt. Release refuses further delivery.
- `install` in an isolated home links both skills to the canonical resource.
  `install --browser-profile DIRECTORY` writes only that profile's native host
  manifest. The removed product `--browser` option is refused without contacting
  the fake debugging endpoint.

The existing CDP proof driver arranges dummy pages and checks boolean results
such as cleared fields. It is not a product receiver. During the real agent
runs, Chrome has no debugging endpoint at all.

## Uncoached agents and the restart result

The full canonical skill was followed by this task, changing only the port and
job name between agents:

> Task: Sign in to the dummy website
> Sign in to http://127.0.0.1:PORT/login?job=NAME using its saved login, and check that retrying a completed sign-in step does not submit twice. Report whether you signed in. Only a shell is available. Your browser tab is already open headlessly; leave other apps and profiles alone.

Claude Code ran on the mini through its authenticated T3 harness. Codex CLI ran
there through its normal ChatGPT authentication and settings, without a sandbox
override. Both chose `tabs`, `fields` and `fill`, inspected the new document
after navigation, completed the code step and released the lease. Their shell
commands and the site's independent submission counts were inspected, in
addition to scanning the complete transcripts for fixture secrets and common
encodings. Account metadata from `find` is intentionally visible.

The driver stopped Chrome after its first accepted password and reopened
`/login` without session restoration. **That loses the website's pending
two-factor session.** The replay records the subsequent HTTP request with no
pending or authenticated cookie. Each agent therefore produced two accepted
password POSTs in different documents, followed by one accepted TOTP POST,
using one lease. The second password POST is a new sign-in step, not a duplicate
retry. Repeating the original target returned its receipt. The implementation
does not promise deduplication between different documents: those are different
actions, and reusing an explicit key for a changed action is refused.

## Replay and packaging

Build the CLI and fixture with the repository's pinned Go toolchain. Run this
on the mini with an unpacked Chrome for Testing executable and this checkout's
extension directory:

```sh
python3 -B script/prove_cli.py \
  --cli build/cli/agent-keyring --fixture build/cli/lease-fixture \
  --browser "/path/to/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
  --extension "$PWD/BrowserExtension"
```

`script/prove_fields.py` also accepts `--codex /path/to/codex` or
`--external-claude`. The latter prints a workspace and writes `setup.json` and
`prompt.txt`; its authenticated harness runs that prompt there, saves the full
session as `events.jsonl`, and writes its exit status to `finished`. Each run
uses a private temporary directory and stops its browsers and authority.

`script/build_cli.sh` produces the universal macOS binary at
`build/cli/macos/agent-keyring`. App packaging copies `BrowserExtension` to
`Contents/Resources/AgentTools/BrowserExtension` beside the canonical skill.
The standalone Nix package includes both resources under `share/agent-keyring`.
CLI and relay Nix builds passed; no Nix configuration was applied.
The final client also cross-compiles for Linux amd64.

The final full CLI run was `/tmp/ak-cli-tacaffs1`, with extension checks in
`/tmp/ak-ext-xw3acfhg`. Claude's complete session was
`/tmp/ak-ext-7py1hr4x/claude/events.jsonl`; the subsequent final Codex run was
`/tmp/ak-ext-sgwobosp/codex/events.jsonl`. Private copies of their prompts,
transcripts, fixtures, output, counts and final artifact hashes are retained in
`.private/proofs/browser-extension/` in this worktree, outside git. Disposable
profiles and authority/receiver state are cleaned after the runs.

The final Codex run recorded the following SHA-256 values before starting:

| Artifact | SHA-256 |
| --- | --- |
| Mini arm64 CLI, ad-hoc signed for execution there | `935711e80c54e02223c20f0895de77bb9d7b8cb094699d2de755b4327dff0b1f` |
| Extension manifest | `df2905f59dfe4a00228ade675d8c199bf9a7c62f3a74507674493ca8ec30981c` |
| Extension background | `5981fc6bef1d44f576a5fa069030ce5f61ce55ab6fd14e18b76079e3bcddaefd` |
| Extension content script | `64001c19a89d6b351406dae60710824c29b90e4c3544d90524d1beb556de23a4` |
| Bundled skill | `fea262a0b4de55d8847ff1d708b39acaf05b2fc186ff6db185d24348a341b931` |

This is not yet proof of installation in Josh's ordinary Chrome, Claude in
Chrome, or Safari. Linux desktop Chromium through the relay is proved
separately in [the F4 record](linux-desktop-browser.md). Closed built-in
browsers do not gain an unsupported credential fallback.

Chrome's native host search path follows its user-data directory
([Chromium source](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/common/chrome_paths.cc)),
which permits the isolated profile registration. The implementation uses
[native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
and [document-targeted isolated scripts](https://developer.chrome.com/docs/extensions/reference/api/scripting).

## Submission and cleanup repair

A fresh review found three real page failures in the first slice. They were
reproduced through the real CLI, native host and extension on the mini before
changing the receiver. On an asynchronous handler that read the inputs after
200 ms, the old receiver reported success but the site rejected the cleared
credentials. An initially disabled button and a JavaScript login without a
`form` element were refused before any POST. The reproduction is retained in
`.private/proofs/browser-extension-review/reproduction/`.

The receiver now fills first, dispatches input/change and focus/blur events,
and waits for a disabled button to become ready. Explicitly selected inputs and
buttons need no form element; the document, origin, selector and field checks
remain. Controls associated with different HTML forms are still refused.
Native HTML validation is checked before clicking a submit button.

A click alone no longer means Submitted. Native form-data capture confirms a
normal submission. For script-driven submissions, full page departure, a URL
change (including `history.pushState`), or removal of all filled controls is a
completion signal. Submitted describes that sign-in **step**, including a step
that displays an error; the agent still has to confirm authentication. The
receiver clears the typed controls after that signal, with input/change events
so controlled inputs also drop their stored value.

If no completion is observed within ten seconds from filling, it clears the
controls and reports Uncertain. There is no generic browser event that proves
arbitrary JavaScript has finished reading an input. A handler that remains on
the same page with the same controls, or reads only after the deadline, can
therefore remain Uncertain. This does not grant another approval or click
again: the receipt still suppresses retries until an inspected `--again`.

The existing `script/prove_fields.py` and dummy site now cover:

- Delayed asynchronous reads, initially disabled buttons, form-less JavaScript
  logins, and all three together: one accepted password and one accepted saved
  TOTP, with an authenticated account, under one lease for each page shape.
- Blur-driven validation and controlled inputs that redraw from stored state.
  Cleanup remains empty after a further second of page activity.
- In-place URL changes, form replacement for a next step, and form replacement
  for an error: prompt completion without waiting for a full navigation. The
  deliberate error receives one rejected POST and is not called authenticated.
- A permanently disabled button and an incomplete required field: zero POSTs,
  a clear refusal, and empty inputs.
- A handler that neither navigates nor replaces controls: Uncertain after ten
  seconds, empty inputs, and no second click on an ordinary retry.

The original identical-tab, frame-scope, changed-retry-key, browser-restart and
killed-helper checks also pass. No secret is returned by `fill` or `fields`.

Fresh Claude Code and Codex CLI runs used the combined asynchronous,
initially-disabled, form-less site for both password and TOTP. Each used `tabs`,
`fields` and `fill`, reached `/account`, checked completed-step retries and
released one lease. The site's counts, independently of their reports, show:

| Agent | Accepted password POSTs | Accepted code POSTs | New leases |
| --- | ---: | ---: | ---: |
| Claude Code | 2 | 1 | 1 |
| Codex CLI | 2 | 1 | 1 |

Both first password POSTs were accepted **before** the injected restart. The
next login request had no pending or authenticated cookie. Claude's statement
that the first step “had not taken effect” is therefore too strong: it happened,
but the restart lost the site's pending session. The second password POST in a
new document was needed. Retrying a completed password or code action added no
POST. The fixture grants access automatically; this is not a real human approval
or Touch ID proof.

The complete agent transcripts and CLI output were scanned for the generated
password, TOTP seed, codes over the run's time range, and common encodings. No
matches were found. The agents' complete shell commands were also inspected:
neither wrote a browser client or handled a secret. Their browsers had no
debugging port. No candidate binary ran on the MacBook, and nothing was
installed globally.

The agent run is `/tmp/ak-ext-6y8ma99k`; the final unchanged full CLI replay is
`/tmp/ak-cli-7501_u08`, with extension checks in `/tmp/ak-ext-5pzr2ijj`. Private
copies of the transcripts, prompts, fixtures, counts, output and artifact hashes
are in `.private/proofs/browser-extension-review/` in this worktree, with a
second private copy in the main checkout at
`.private/proofs/browser-extension-submission-6y8ma99k/`. Disposable profiles, authority state and receiver state were cleaned after the runs.

The exact receiver and skill used by both agents have SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| Fresh mini arm64 CLI | `3e048e8301510f3974a7da02a84faa19a80c0f698033c0fc889cceaecf564e6b` |
| Extension content script | `79b05ccefa52de08e044080406e38051643c23216fa83376814daf214dd60f0b` |
| Bundled skill | `dae4fa4b6985640b0cf06d508f4af1ddad1a28357f5eeaccb156fc4ec4e01119` |

`script/build_cli.sh` was rerun locally without executing the candidate there.
`build/cli/macos/agent-keyring` contains both x86_64 and arm64; its SHA-256 is
`3cf980860753209c82920ad582cc6b49a58050254fc6bcab0ba9c3f237cbd5e1`.
The fresh mini build's help advertises `tabs`, opaque targets and the extension,
with no debugging-port filling workflow. Broader browser installation and
harness support remain the separate slices listed above.
