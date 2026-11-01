<!-- Written by AI on 2026.10.31 by model gpt-6.1-sol. -->

> Historical debugging-port proof. The current path is covered by the
> [browser extension proof](browser-extension.md).

# Release 2 CLI and receiver proof

The shell workflow runs against a dummy protobuf authority and a real signed
Google Chrome debugging endpoint on the Mac mini. It does not read the installed
vault, ask for real credentials, install the app, or change access rules.

Build with the pinned toolchain:

```sh
nix shell github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go -c sh -c '
  go build -o build/cli/agent-keyring ./cmd/agent-keyring
  go build -o build/cli/lease-fixture ./script/lease_fixture
'
python3 -u script/prove_cli.py
```

Run the browser proof on the mini, never on the user's MacBook. It launches a
headless browser with its own temporary profile and stops every process it starts.
Its private temporary directory contains the generated dummy fixture, persisted
protobuf leases and receiver receipts, and captured CLI output. The receiver
uses an isolated home and state directory, including for local-socket use.
It prints that directory's path.

The proof exercises:

- Private `read` consumption, task rejoin, and release refusing further reads.
- An approved program receiving stdin, deliberately echoing it on both output
  streams, and exiting 7. The CLI suppresses that output, retains the exit status,
  and avoids starting the program again on retry. `--again` starts it deliberately.
- Password then TOTP sign-in in real Chrome, with the authenticated page checked.
- Receiver-owned receipts survive navigation to the code form and authority
  restart. A new CLI process reports the saved result without a second POST;
  a code fill under the same lease completes the login.
- SIGKILL during a browser submit leaves Started in the receiver's state file.
  Chrome finishes the submit; the next CLI reports Uncertain and the site sees
  one password POST. Killing a receiver during a program has the same result.
- Reusing an explicit operation key with a changed field or selector is refused
  before returning an old result or inspecting the changed page.
- A page that retains its form after submission, with direct boolean checks of
  residual clearing. A password target pointing at a textarea is refused.
- Concurrent CLI fills sharing a tab, and a fake loopback debugging endpoint.
- Installing the command and both skills into an isolated home, then comparing
  the installed instructions with the canonical resource.
- Literal and commonly encoded fixture values absent from receiver output. Find
  deliberately exposes account metadata and is outside that artifact scan.

`./script/build_cli.sh` produces the universal macOS helper at
`build/cli/macos/agent-keyring`. The release script invokes it before Xcode;
`bundle_agent_tools.sh` must copy that helper and the canonical `AgentSkill`
resource into the app. Skills are linked to that resource, so app updates change
instructions with the binary. Existing copied skill directories are preserved
beside their replacements.

The same Go CLI also cross-compiles for Linux. Remote transport and sealed
bundle opening are covered in [the remote proof](remote-requests-client.md).
Browser endpoint ownership is currently proved for signed Google Chrome on macOS, by matching the listening
process and its code signature. Other Chromium builds and platforms return
unavailable. The receiver supports ordinary editable inputs and explicit submit
controls in the same form; cross-process frames, shadow roots and split-code
widgets remain unsupported. It does not pause other agent observation channels.

The dummy authority proves client behavior, not the Mac authority's policy,
biometric approval or persistence. The release 2 joint proof used the real
authority with isolated dummy data; it needs the simplified Deliver contract
before a new joint run. A Touch ID session and real harness sign-ins remain
release-level checks.
