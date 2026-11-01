<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Linux desktop browser through the relay

RFC 0009 F4 uses the existing Linux installer and native host. No production
transport or platform-specific receiver was added. The new fixture mode lets
the scripted approver seal the existing dummy site's generated login and
time-bounded TOTP codes to the enrolled receiver. Its seed stays at the source.

The proof runs Chromium 154.0.8037.97 in desktop mode on a private Xvfb display,
with a separate profile for each agent. There is no `--headless` or debugging
port. The production relay executable runs as its own process on an unused
Tailscale-address port, with private temporary state. It uses the normal
Tailscale node lookup, TLS pairing, signed configuration and CLI enrolment.
The native host selects the saved relay without `AGENT_KEYRING_SOCKET`,
`AGENT_KEYRING_RELAY` or `AGENT_KEYRING_STATE_DIR` overrides.

The Linux installer already writes the host manifest under
`NativeMessagingHosts` in each supported browser's user-data directory. The
proof runs the complete installer with both a temporary HOME and a temporary
`XDG_CONFIG_HOME`. It checks Chrome, Chrome for Testing, Chromium, Brave and
Edge paths, the exact extension allowlist, absolute executable path, private
file permissions and both installed skill links. The live browser uses the
Chromium manifest from this ordinary installation, rather than the
`--browser-profile` test shortcut. The paths follow
[Chrome's native-messaging contract](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).

## Run

Build on Linux using the project's Go toolchain. Keep the executable, skill
and extension in the standalone package layout:

```sh
mkdir -p build/f4/bin build/f4/share/agent-keyring/skills
go build -o build/f4/bin/ ./cmd/agent-keyring ./cmd/agent-keyring-relay ./script/relay_fixture
cp -R AgentSkill/agent-keyring build/f4/share/agent-keyring/skills/
cp -R BrowserExtension build/f4/share/agent-keyring/
python3 -B script/prove_linux_browser.py \
  --cli "$PWD/build/f4/bin/agent-keyring" \
  --relay "$PWD/build/f4/bin/agent-keyring-relay" \
  --approver "$PWD/build/f4/bin/relay_fixture" \
  --extension "$PWD/build/f4/share/agent-keyring/BrowserExtension" \
  --browser /path/to/chromium --xvfb /path/to/Xvfb \
  --codex /path/to/codex --claude /path/to/claude
```

Agent arguments select authenticated command-line agents. The prompt contains
the full bundled skill and an ordinary request to sign in to the dummy URL
and check a completed-step retry. The agent chooses its tab and selectors.
The fixture gives one scripted HUMAN approval per lease; no real Touch ID,
Face ID, imported login or installed vault is used.

The tested Linux machine's standalone Codex CLI runs read-only by default; its
saved configuration lacks the full-access setting used on the Macs. That
first run stopped before requesting a lease. With explicit authorisation,
`--codex-full-access` passes `-c 'sandbox_mode="danger-full-access"'` to this
proof's Codex process only. It does not edit the global Codex configuration.
This is a machine configuration finding, rather than a keyring failure.

The script checks the site's independent password/code counts and authenticated
page, the relay approver's decision count, the actual agent commands and
recorded retry result. Full transcripts and CLI output are scanned for the
generated password, TOTP seed, possible codes and common encodings. Account
metadata is intentionally visible.

All test processes stop in `finally`. `tabs` prunes a disconnected helper's
socket after browser shutdown. Proof artifacts are private, and disposable
profiles, keys and state are moved to Trash after collecting the evidence.
No system services, ordinary browser profiles, shared agent configuration or
global installation are changed.

## Observed result

Both authenticated Linux agents passed on 1 November 2026 against the real
relay, native host and receiver. Each run started with fresh relay, client and
browser state. The site used delayed JavaScript submission, a button disabled
until input was accepted, and no HTML form.

| Agent | Relay approvals | Accepted password POSTs | Accepted code POSTs | Retry |
| --- | --- | --- | --- | --- |
| Codex CLI 0.166.0 | 1 | 1 | 1 | Already submitted; no extra POST |
| Claude Code 2.1.312 | 1 | 1 | 1 | Already submitted; no extra POST |

Both agents reached `/account` and released their lease. The transcript scans
passed, and all proof processes stopped. Codex's saved configuration had the
same SHA-256 before and after its explicitly authorised run. The default
read-only attempt is retained separately and is not counted as a pass.

Private prompts, transcripts, dummy fixtures, counts, cleanup results and
artifact hashes are retained outside git in
`.private/proofs/linux-browser/`. The production Linux CLI's SHA-256 was
`a21375db408f4f94db15970960cc8bbf97e63b3a98c7e9626f4f8651ba5f0f9c`;
the isolated relay executable's was
`d6c9c8a7ff98bc084ac817143c3655f38bc6da1578eeeb8c94558f6af611645a`.

This proves desktop Chromium through a relay with scripted dummy approval.
It does not prove real biometric approval or installation in an existing
personal browser profile.

## Extension version

Main was merged again before the agent runs. The completion and cleanup repair
is `adec64f`; the exact `page.js` SHA-256 is
`79b05ccefa52de08e044080406e38051643c23216fa83376814daf214dd60f0b`.
This lane did not change that file.
