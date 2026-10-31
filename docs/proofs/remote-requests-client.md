<!-- Written by AI on 2026.10.31 by model gpt-6.1-sol. -->

# Remote client proof

The production Go CLI enrolled on `mini-server-1` and completed dummy program
and agent-process sign-ins through the production Go relay on the Mac mini,
over Tailscale. A fixture approver supplied synthetic example.com credentials.
No Passwords mirror, human approval, real account or installed app was used.

Observed:

- Enrol printed its locally computed eight-group fingerprint and accepted the
  signed enrolment record. `find example.com` verified the signed login index.
- A program lease delivered the password through stdin. The fixture program
  checked it and wrote a success marker. Its echoed password was suppressed.
  A second CLI process retried the same operation; the marker still showed
  one execution. Release succeeded.
- An agent-process lease delivered the password to a private receiving process,
  which compared it without printing it. The key file had mode 0600.
- After SIGKILL and restart of the relay, with the fixture approver disconnected,
  a new CLI process opened the same active lease and released it. It needed no
  new approval.

The relay listened on the mini's tailnet address, port 17443, with real
Tailscale WhoIs checks. The relay lane's port 17444 was not used. Every process
and state directory created for this proof was stopped or removed afterward.

## CryptoKit and receiver proof

`script/prove_remote_cli.py` runs the real CLI against the deliberately small
`script/remote_fixture` relay/approver stand-in. It is not the production relay
or an authentication implementation. On the mini, `script/seal_dummy_bundle.swift`
uses CryptoKit for both HPKE sealing and DER ECDSA signatures over the exact
protobuf statement bytes. The CLI uses Go's `crypto/hpke` and `relaycrypto.Verify`.

The complete process proof passed on the mini:

- Program and agent-process delivery, current code delivery, private key file,
  locally derived enrolment fingerprint, signed login index.
- Wrong recipient, wrong lease, expired signed deadline, unknown signer and
  changed ciphertext each refused with a clear error and no value on stdout.
- A changed signed task, invalid encapsulated key, wrong opened login and invalid key-chain signature
  refused too.
- Automatic signing key accepted only with the current owner's grant and the
  machine's signed Automatic permission. A signed key update from the pinned
  predecessor accepted the new signer; the removed signer was then refused.
- A verified HUMAN/DENY reply appeared in both lease failure and later status.
  Changed replies, unsigned replies and replies with an unexpected bundle
  attachment were hidden. Denial history is not subject to active-lease expiry.
- Signed headless Chrome completed the dummy password step and then a dummy
  code step. A bundle with the wrong saved site entered nothing. Retrying the
  successful password operation caused one password POST. An SPA retained its
  form after submit; the inputs were empty after the receiver returned.

The final file-storage binary passed this proof without a signed wrapper.
Keychain experiments were discarded. Remote keys are owner-only files; this
is not a Keychain protection claim. The state directory defaults to
`$XDG_STATE_HOME/agent-keyring` or `~/.local/state/agent-keyring`, mode 0700.
`keys.pb` and `state.pb` are mode 0600. State includes pinned keys, signed grant
and index revisions, and the request scope retained across CLI processes.

Run the fixture proof on the mini, from a checkout with the pinned Go:

```sh
./script/build_cli.sh
go build -o build/remote-fixture ./script/remote_fixture
swiftc script/seal_dummy_bundle.swift -o build/seal-dummy-bundle
python3 script/prove_remote_cli.py \
  --cli build/cli/macos/agent-keyring --fixture build/remote-fixture \
  --cryptokit build/seal-dummy-bundle --browser
```

The `--browser` flag is for the mini only. The proof creates and removes its
own profile, server, keys and state. Without that flag it opens no browser.
The local R2 CLI proof (`script/prove_cli.py`) also passed after these changes,
including two-step Chrome, uncertain retry after navigation/restart, cleanup,
concurrent fills, endpoint ownership and installation into an isolated home.

## Real relay setup and build

The relay lane supplied the production `agent-keyring-relay` and
`script/relay_fixture --mode approver`. Start them with fresh private state,
then enrol the Linux CLI using `enrol --name NAME --relay HOST:PORT`. The fixture
publishes `fixture-login`. A program lease binds an absolute executable and
arguments; the fixture program must consume the password privately on stdin.
The fixture approver deliberately replaces Josh's fingerprint comparison and
Touch ID, so those remain device proofs.

`script/build_cli.sh` still creates the universal helper at
`build/cli/macos/agent-keyring`, with CGO disabled. Release builds call it before
Xcode; helper packaging is unchanged. The client requires Go 1.26 for stdlib
HPKE, provided by the existing pinned nixpkgs revision. A Linux amd64 binary was
built with that Go using `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build`, then
copied into a temporary directory on `mini-server-1`. No system install occurred.
For remote distribution, keep the canonical `AgentSkill/agent-keyring` directory
beside the binary or in an ancestor, so `skill` and `install` can find it.

`AGENT_KEYRING_SOCKET` explicitly selects the local socket. Otherwise a Mac with
the app uses its local authority, starting it if needed. Remote machines use
the saved relay. `AGENT_KEYRING_RELAY=HOST:PORT` explicitly selects an already
enrolled relay and supplies enrol's default address; a changed address is not
silently trusted. `AGENT_KEYRING_STATE_DIR` isolates a receiver for proofs.

Still outside these proofs: the real Mac approver's outbox and Touch ID,
revocation/device setup by Josh, and Linux browser endpoint ownership. Linux
supports the program and agent-process routes; its Chromium receiver still
reports that endpoint ownership is supported on macOS only.
