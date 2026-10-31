<!-- Written by AI on 2026.10.31 by model gpt-6.1-sol. -->

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
protobuf receipts, and captured CLI output. It prints that directory's path.

The proof exercises:

- Private `read` consumption, task rejoin, and release refusing further reads.
- An approved program receiving stdin, deliberately echoing it on both output
  streams, and exiting 7. The CLI suppresses that output, retains the exit status,
  and avoids starting the program again on retry. `--again` starts it deliberately.
- Password then TOTP sign-in in real Chrome, with the authenticated page checked.
- A lost Finish reply, navigation to the code form, authority restart, and retry
  from a new CLI process. The retry reports uncertain and the server sees one
  password POST. A code fill under the same lease completes the login.
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

The Go CLI also cross-compiles for Linux. Release 2 has only local Unix transport;
opening sealed remote deliveries is a later slice. Browser endpoint ownership is
currently proved for signed Google Chrome on macOS, by matching the listening
process and its code signature. Other Chromium builds and platforms return
unavailable. The receiver supports ordinary editable inputs and explicit submit
controls in the same form; cross-process frames, shadow roots and split-code
widgets remain unsupported. It does not pause other agent observation channels.

The dummy authority proves client behavior, not the Mac authority's policy,
biometric approval or persistence. The next joint check uses the real authority
with isolated dummy data. A Touch ID session and real harness sign-ins remain
release-level checks.
