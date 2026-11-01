<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Chromium on macOS and Linux

The real `agent-keyring fields` and `fill` commands completed password and saved
TOTP sign-in under one browser-purpose lease on all six builds below. The
browser reached the authenticated `/account` page. No password, code or seed
appeared in CLI output. A stand-in authority supplied generated dummy logins;
no vault, real account or installed Agent Keyring state was used.

| Platform | Browser | Version | Installation used |
| --- | --- | --- | --- |
| macOS 26.6.2, arm64 | Google Chrome | 156.0.8078.74 | Existing signed application |
| macOS 26.6.2, arm64 | Chrome for Testing | 156.0.8078.80 | Official mac-arm64 archive, unpacked temporarily; ad-hoc signature |
| macOS 26.6.2, arm64 | Chromium | 141.0.7390.37 | Existing Nix-managed Playwright Chromium 1194; ad-hoc signature |
| NixOS, x86_64 | Google Chrome | 156.0.8078.79 | Official Debian package, extracted temporarily without installing |
| NixOS, x86_64 | Chrome for Testing | 156.0.8078.80 | Official linux64 archive, unpacked temporarily |
| NixOS, x86_64 | Chromium | 154.0.8037.97 | Nix package |

The Mac proof used the universal binary produced by `script/build_cli.sh` at
`build/cli/macos/agent-keyring`. Linux used the same Go command, cross-built for
linux/amd64. Neither browser verification nor delivery changes the agent-facing
commands or the authority protocol.

## What the system proof checks

`script/prove_cli.py` now takes `--cli`, `--fixture` and `--browser`, so the same
existing system proof runs against each executable. Every run checks:

- `fields` lists the real tab and its field metadata. The proof passes its
  printed selectors to `fill`, then inspects the code form with `fields` and
  fills that under the same lease. The site accepts one password and one TOTP
  submission, and both the browser and `fields` observe the account page.
- A browser lease cannot be read as an agent-process password. No purpose
  changes or disclosure fallback are used for sign-in.
- Retrying the first fill after navigation and an authority restart returns
  its saved result and sends no second password POST. Reusing an explicit
  operation key with changed selectors reports a conflict.
- Killing the CLI during a real submit leaves an uncertain receipt. The site
  receives one password POST; a new CLI process reports uncertainty without
  submitting again.
- A form that remains on the page after submission has empty inputs. Explicit
  `--again` submits deliberately; two racing CLI processes submit only once.
  An inappropriate field is refused without writing to it.
- Both `fields` and `fill` refuse a non-browser HTTP listener. The dummy server
  offers a Chrome-looking `/json/version`, but its request count remains zero:
  ownership is checked before that response is read.
- Fill writes no stdout. Collected output contains none of the fixture values
  or the common encodings checked by `check_login_artifacts.py`.
- The existing program, interrupted-program, agent-process, release and
  installation workflows still pass.

`script/prove_fields.py` also passed on both operating systems. It inspects
populated fields before any authority is running, without returning or changing
their values. Its generated selectors handle missing and duplicate IDs and
exclude hidden controls; the receiver accepts them for a real fill and clears
the inputs afterward. These runs used Nix Chromium with a minimal receiver
`PATH`, also proving that its store registration check finds Nix without
depending on the agent's shell setup.

The captured stdout is in [chromium-platforms.stdout.txt](chromium-platforms.stdout.txt).
It includes the account page metadata printed by the actual CLI. Temporary
credentials and browser profiles are not part of this record.

## Endpoint identification and its limit

The receiver still accepts only local loopback endpoints. On macOS, `lsof`
binds the listener to one PID, and the kernel's `kern.procargs2` supplies the
actual executable path. Branded Google Chrome still requires Google's
Developer ID signature. Chrome for Testing and Chromium require their native
application executable, matching bundle metadata and framework version,
framework code, and Chromium resources. Their linker code signatures are
checked without assuming a sealed resource envelope or a publisher identity.

On Linux, `/proc/net/tcp*` and `/proc/PID/fd` bind the listening socket to one
process owned by the receiver's user. `/proc/PID/exe` identifies its actual
native ELF executable, alongside its Chromium resources. PID and process start
time identify the browser instance for retry records. If an executable is in
the Nix store, both platforms check that its containing store path is registered.
No browser name or HTTP version response alone admits an endpoint.

These checks identify an installed browser and reject an ordinary fake
debugging server. They do not authenticate the publisher of an ad-hoc or
unpacked build, or isolate hostile software running as the same user. There is
no browser certification service, new trust database or weaker delivery mode.

## Replay

Build the CLI and dummy authority with the project's pinned Go toolchain:

```sh
./script/build_cli.sh
nix shell github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go \
  -c go build -o build/cli/lease-fixture ./script/lease_fixture
# Linux binaries, from the same checkout and toolchain:
nix shell github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go \
  -c env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o build/cli/agent-keyring-linux ./cmd/agent-keyring
nix shell github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go \
  -c env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o build/cli/lease-fixture-linux ./script/lease_fixture

python3 -B -u script/prove_cli.py \
  --cli /path/to/agent-keyring --fixture /path/to/lease-fixture \
  --browser /path/to/browser-executable
python3 -B -u script/prove_fields.py \
  --cli /path/to/agent-keyring --fixture /path/to/lease-fixture \
  --browser /path/to/browser-executable
```

Run these only on an owned test host. Each run creates a temporary profile and
launches that browser with `--headless=new` and an automatically assigned
debugging port. It stops only the processes it started. No existing profile,
window, focus, native input or website session is used. The Mac runs were on
the mini; nothing ran on the MacBook's screen. Proof state and downloaded
archives were trashed after checking the results.

On NixOS, the unpacked official Chrome builds needed shared libraries already
in the Nix Chromium closure. The proof supplied those directories through
`LD_LIBRARY_PATH` and `NIX_LD_LIBRARY_PATH` to its own processes. It installed
no package or profile and changed no machine configuration.

The Chrome for Testing archives came from Google's
[published download index](https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json).
The Linux Google Chrome package came from
[Google's download endpoint](https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb).
The Linux process inspection uses the kernel's documented
[/proc interfaces](https://www.kernel.org/doc/html/latest/filesystems/proc.html).

Safari and closed agent browser tools are outside this proof. Existing browser
sessions remain the responsibility of the agent's browser, as before.
