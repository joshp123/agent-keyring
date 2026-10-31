<!-- Written by AI on 2026.10.31 by model gpt-6.1-sol. -->

# Shell-only sign-in with fields

A fresh real Codex run signed in with the bundled skill and shell commands
alone. It used `fields` to discover the tab and each step's controls, completed
password and saved TOTP, confirmed the Account page and released the lease.
It wrote no Chrome client code or task files. The dummy site received exactly
one accepted password POST and one accepted code POST.

This ran on the Mac mini against a stand-in authority and signed headless Google
Chrome, in an isolated profile. No windows, native input, installed app, real
account or Passwords data were involved. The mini's existing screen was untouched.

## Helper proof

`script/prove_fields.py` uses the real CLI and the existing dummy login server:

- Before an authority is running, list page tabs with IDs, URLs and titles,
  and list visible controls with selectors, types, names, IDs, labels and
  autocomplete metadata.
- Populate username and password inputs, inspect them, then check the values
  are unchanged. Neither value appears in output. The helper produces no POST.
- Pass its printed selectors to `fill` for password and then TOTP; check the
  authenticated page and one accepted submission per step.
- Exercise duplicate and absent IDs, a unique name and button text. Pass the
  generated fallback selectors to `fill`, submit once and check input clearing.
  Hidden inputs and buttons are absent from the listing.
- Refuse a loopback HTTP server that is not the signed Chrome process.

Inspection uses the existing Chrome ownership check and connection code.
It does not ask the authority for anything or require a lease. It inspects the
main document's ordinary inputs and buttons; it is not a general browser tool.

## Uncoached Codex proof

The mini's ChatGPT-bundled `codex exec` used its normal identity and configuration,
without a sandbox override. Its input was the canonical bundled skill, verbatim,
followed by this task (the loopback ports below belonged to this run):

> Task: Sign in to the dummy website
> Sign in to http://127.0.0.1:49512/login using its saved login, then report whether you signed in.
>
> Only a shell is available. Google Chrome is already open headlessly at http://127.0.0.1:49513. Use that browser; leave other apps and browser profiles alone.

No implementation brief, command sequence, hints or follow-up were supplied.
The transcript contains only agent messages and shell command executions.
Its nine commands, with the run-specific lease and tab IDs replaced below,
were:

```sh
agent-keyring find http://127.0.0.1:49512
agent-keyring fields --browser http://127.0.0.1:49513
agent-keyring fields --browser http://127.0.0.1:49513 --tab TAB
agent-keyring lease dummy --task dummy-signin-20261031-49512 --reason 'Sign in to the dummy website as requested'
agent-keyring fill LEASE --browser http://127.0.0.1:49513 --tab TAB --username '#username' --password '#password' --submit '#sign-in'
agent-keyring fields --browser http://127.0.0.1:49513 --tab TAB
agent-keyring fill LEASE --browser http://127.0.0.1:49513 --tab TAB --code '#verification-code' --submit '#verify'
agent-keyring fields --browser http://127.0.0.1:49513 --tab TAB
agent-keyring release LEASE
```

It answered:

> Signed in successfully, including two-factor verification. The browser reached the Account page, and I released the login lease.

The task directory was empty afterward. Its commands contained no Python,
Node, WebSocket implementation or direct Chrome protocol call. The password,
TOTP seed and current codes, including common encodings, were absent from the
transcript. Account metadata from `find` is intentionally public to the agent.
Raw prompt, transcript, commands and answer are retained privately in
`.private/proofs/shell-only-fields/`; the proof chat was archived.

## Replay

On the mini, with the repository's pinned Go:

```sh
./script/build_cli.sh
nix shell 'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go' \
  -c go build -o build/cli/lease-fixture ./script/lease_fixture
python3 -u -B script/prove_fields.py \
  --cli build/cli/macos/agent-keyring --fixture build/cli/lease-fixture \
  --codex /Users/josh/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
```

Without `--codex`, this runs only the helper and two-step CLI proof. Every
browser and authority it starts is stopped in cleanup. It prints its private
artifact directory; move it to Trash when inspected. The proof's copied runtime
and temporary state were moved to Trash after this run. The universal macOS
build, Linux cross-build and targeted `go vet` passed.
