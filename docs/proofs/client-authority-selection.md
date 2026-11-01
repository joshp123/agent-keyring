<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Persistent authority and standalone client

The client now follows its saved authority. Completed, signed enrolment selects
the relay before any local app or socket discovery. Otherwise the first local
use records the app path and bundle ID in the existing private protobuf state.
A failed connection does not change that selection. Explicit environment
overrides remain temporary; supplying both connection overrides is an error.

## Mini system proof

The physical Mac mini (macOS 26.6.2, arm64) ran the real CLI, current Go relay,
existing dummy sender, a dummy local authority and signed headless Google Chrome.
All state, logins, website and browser profiles were isolated. The relay used
the mini's tailnet address and an ephemeral port, with the real Tailscale check.
The production relay service and its state were untouched.

The CLI came from `nix build .#agent-keyring --out-link build/cli/nix`.
The unchanged package tree was copied into the mini's temporary directory;
no Nix profile or user configuration was installed. Its binary SHA-256 was
`811ece2923b1f25fd79c7624014b1f2e6624254da7d0a7b4282d442c29c7fae1`.
The universal app helper came from `script/build_cli.sh`. A private copy of the
real app contained that helper, signed using the normal Mac build identity;
the enclosing app was re-signed after replacing it. Build and signing ran on
the MacBook; neither candidate executable ran there. The app copy was used only
on the mini, outside `/Applications`, and never launched.

The existing `script/prove_automatic_copy.py` checks:

- A local socket alone cannot choose an authority. Running the bundled helper
  selects its app; a subsequent standalone invocation finds the same local
  dummy login, proving the selection survives across executable entry points.
- The standalone package prints its canonical skill. `install` repairs three
  dangling app links in a private home: the command and both harness skills.
- Enrolment completes while the full app copy and its working local socket are
  present. Both the bundled helper and standalone client subsequently find the
  relay's different login without either connection environment override.
- With that relay stopped, both commands refuse with its address in the error.
  They do not read from the still-present local authority or launch the app.
- With the sender exited, password and saved TOTP fill under one lease and
  reach the website's authenticated page. Retrying the first step sends one
  password POST. Ordinary output is checked for the fixture password and seed.
- Relay restart, password refresh, exact delivery retries, copy rejection,
  Automatic-to-Ask/Blocked and full copy replacement retain the existing
  lease/retry behavior.

The first attempted run used the mini's deployed relay executable. It predates
the Automatic-copy bootstrap protocol and refused the fixture before pairing.
The passing run therefore used the current relay built from this checkout,
still with isolated state. The captured passing output is
[client-authority-selection.macos.stdout.txt](client-authority-selection.macos.stdout.txt).

All proof copies, including those from failed setup attempts, were unregistered
with `pluginkit -r` and `lsregister -u`. The final pluginkit list contained no
Agent Keyring extension; LaunchServices contained none of the copied paths.
`/Applications/AgentKeyring.app` remained absent. Owned relay, fixture and Chrome
processes stopped, and their apps, profiles and state were moved to Trash.
No existing browser, screen, focus, native input, installed vault or real login
was used. Cleanup output is in
[client-authority-selection.cleanup.txt](client-authority-selection.cleanup.txt).

## Linux system proof

On `mini-server-1`, the same client source, built for linux/amd64, passed the
existing `script/prove_remote_cli.py` against its TLS authority fixture.
The proof removes `AGENT_KEYRING_RELAY` immediately after enrolment; subsequent
commands therefore use the saved selection. Program sign-in, private process
delivery, retry conflict detection, sealed-bundle refusals, signed denial
replies, current Automatic configuration and signer rotation all passed.
The run used a temporary directory and no machine configuration changes.
Output is in
[client-authority-selection.linux.stdout.txt](client-authority-selection.linux.stdout.txt).

## Replay

Use the existing proof scripts and pinned toolchain:

```sh
nix build .#agent-keyring --out-link build/cli/nix
./script/build_cli.sh
nix shell github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go \
  -c go build -o build/cli/relay ./cmd/agent-keyring-relay
nix shell github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go \
  -c go build -o build/cli/relay-fixture ./script/relay_fixture
nix shell github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go \
  -c go build -o build/cli/lease-fixture ./script/lease_fixture
```

Prepare a private, signed candidate app containing this source's helper. Do not
overwrite the helper inside an already signed app without re-signing that
bundle: macOS correctly refuses the changed copy. Copy the artifacts and the
existing proof support scripts to a temporary directory on the mini. Run there:

```sh
python3 -B -u script/prove_automatic_copy.py \
  --cli /path/to/package/bin/agent-keyring \
  --relay /path/to/relay --sender /path/to/relay-fixture \
  --listen MINI_TAILNET_IP:0 \
  --application /path/to/private/AgentKeyring.app \
  --local-fixture /path/to/lease-fixture
```

`--application` is mini-only and refuses an existing `/Applications` app. The
copy stays closed: the fixture serves its bundle-derived socket before the
helper runs. The driver unregisters its app copy in `finally`. Unregister any
additional source copies, check pluginkit, stop owned processes, and move the
printed state directory and transferred artifacts to Trash.

For Linux, cross-build the client and `script/remote_fixture` with
`CGO_ENABLED=0 GOOS=linux GOARCH=amd64`, then run `prove_remote_cli.py --cli ...
--fixture ...` there. Its cleanup uses `trash`; the proof host supplied it with
`nix shell` rather than installing a package.

`go vet ./cmd/agent-keyring ./internal/remote`, protobuf generation and the
universal Mac build also passed. No unit tests or new proof framework were added.

## Nix deployment handoff

The existing flake now exports `packages.${system}.agent-keyring` for arm64 and
x86_64 macOS and Linux. The relay remains the default package. The client has:

- `bin/agent-keyring`
- `share/agent-keyring/skills/agent-keyring/SKILL.md` (the canonical skill tree)

Update the existing Agent Keyring input to the merged revision and select:

```nix
client = inputs.agent-keyring.packages.${pkgs.stdenv.hostPlatform.system}.agent-keyring;
```

Declare the mini's existing command and harness links in its managed home:

| Link | Target |
| --- | --- |
| `~/.local/bin/agent-keyring` | `${client}/bin/agent-keyring` |
| `~/.codex/skills/agent-keyring` | `${client}/share/agent-keyring/skills/agent-keyring` |
| `~/.claude/skills/agent-keyring` | `${client}/share/agent-keyring/skills/agent-keyring` |

The Claude skill directory is already managed and read-only to the user;
deployment should replace its declaration, rather than run `install` against
that directory. Keep the receiver's state in Josh's persistent home, outside
the Nix store. Neither app installation nor Keychain setup is needed.

This proof does not enrol the production mini or repair its real links. Once
deployed, enrol the mini once against its real relay and complete the fingerprint
comparison and approval. The Nix deployment owner handles the actual apply;
this lane made no deployment, push or `/Applications` change.
