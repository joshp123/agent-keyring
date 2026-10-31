# Swift Mac and phone approval together

Written by AI on 2026.10.31 by model gpt-6.1-sol.

## Result

The production Swift Mac approver and production Swift phone core completed
the away-from-keyboard flow together through the real Go relay, Go CLI and
headless Chrome on the physical Mac mini. The Swift production code is unchanged
from `6e09b58`. The local denial case found and fixed one relay bug in `406d010`.

First, the existing full `developer/mac-approver-proof` passed from exactly
`6e09b58e2a5e089169fc7895f6f4888273214756`, including its real CLI and browser
options. This includes pairing/enrolment, human and Automatic decisions,
password/TOTP sign-in, operation retry, durable outbox/restarts, fixed deadlines,
plain/signed denial, hold-off clearing, ending access and configuration revocation.
That original driver covers phone pairing, not phone approval.

The extended driver then passed these joint flows:

- A pending Ask request waits 30 seconds before reaching the phone. Killing
  and restarting the Mac during that wait preserves the request, pending
  deadline and original escalation time. The Swift phone approves; the Mac
  signs with its background delivery key, without Mac human authorization.
- A reported locked state sends the next request immediately. Phone approval
  and Mac background delivery complete the sign-in in that state.
- Once a request reaches the phone, a Mac answer closes it there. A late phone
  Approve is rejected before authorization. The Mac human key signs this case.
- A transparent TLS proxy drops the Mac's acknowledgement after the relay has
  committed its delivery. The driver kills and restarts the Mac and relay.
  The exact saved decision hash, sealed delivery and phone deadline survive;
  the outbox finishes with one phone authorization and one background signature.

Every case signs in through a real CLI receiver and headless Chrome, submits
the password, retries that operation after navigation, submits the current TOTP
and releases the lease. Each controlled site records one password POST and
one accepted verification. The Go receiver verifies the real Swift signatures
and opens the real Swift HPKE bundle. No Go substitute plays either approver.

The fifth case exercises an ordinary local request through the actual Swift
`agent.sock` server and `MirrorAppModel` handler. The fixture uses an encrypted
example.com mirror and the same lease store as its production `RelayApprover`.
No receiving machine is enrolled with the relay. The actual Swift phone core
holds no vault and approves after the 30-second local escalation delay.

To check local reporting independently, the network proxy refuses new Mac
calls while preserving its existing WatchWork stream. The Mac receives the
phone's answer and activates the local lease, but the phone stays **Waiting for
your Mac** until the queued local outcome report is allowed through. The real
local CLI then completes password/TOTP sign-in with one password POST on retry.
Phone End likewise stays unconfirmed until the Mac reports REVOKED. Further
local delivery is refused. A second local request with reported locked state
escalates immediately, completes sign-in, and its CLI release reaches the phone
as **Released**. A phone denial with a signed reply reaches the local CLI
verbatim with a nonzero result. With the report held offline, the Mac and relay
restart; the queued report then moves the phone from **Waiting for your Mac** to
**Denied**. A second Mac, relay and phone restart retains the same denial,
reply and end time. An authenticated relay call reads that retained local result.

These three local actions use two phone approvals and one signed denial,
without another Mac authorization or a remote-bundle background signature.

The relay bug was in its shared response decoration: a local denial with a reply
was looked up in the remote `leases` table to attach a signed delivery envelope.
That expected missing remote row rolled back the valid local outcome update,
leaving the phone waiting. The helper now explicitly attaches remote envelopes
and treats a missing remote record as no envelope. It still returns real storage
or decoding failures. Local reports remain authenticated and scoped to their Mac;
remote denial signatures are unchanged.

After this fix, the fifth case passed, the relay's own full TLS system proof
passed, and `go vet ./...` passed. The four remote joint cases were rerun against
the fixed relay.

## Reproduce

Build the relay, CLI and driver from the same tree:

```sh
devenv shell -- bash -c '
  go build -o build/proof/relay ./cmd/agent-keyring-relay
  go build -o build/proof/agent-keyring ./cmd/agent-keyring
  go build -o build/proof/mac-approver-proof ./developer/mac-approver-proof
  go build -o build/proof/relay-fixture ./script/relay_fixture
  go vet ./...
'
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift build --package-path AgentKeyringPackage --product agent-keyring-relay-approver-fixture
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift build --package-path AgentKeyringPackage --product agent-keyring-phone-fixture
```

The Mac fixture needs the app's existing provisioning profile and entitlements
to use its isolated data-protection Keychain checkpoints. Package/sign that
executable under the existing app identifier, without an extension, and run
only its command-line executable on the mini. Never launch the wrapper on the
MacBook or use `open`. The phone fixture remains the unchanged production-core
fixture from the baseline revision; its software keys are dummy files.

With an unused port 17445 and a fresh `ROOT` inside the app container:

```sh
build/proof/mac-approver-proof \
  --root "$ROOT" \
  --approver "$SIGNED_WRAPPER/Contents/MacOS/RelayApproverFixture" \
  --phone-binary "$PWD/AgentKeyringPackage/.build/debug/agent-keyring-phone-fixture" \
  --relay "$PWD/build/proof/relay" \
  --cli "$PWD/build/proof/agent-keyring" \
  --browser-script "$PWD/script/prove_mac_relay_browser.py"
```

Omit `--phone-binary` to run the original full relay driver. The joint driver
owns its relay, Swift processes, TLS proxy and headless browser. It uses only
the built-in example.com dummy account, no import or real vault. Chrome has
`--headless=new`, a fresh private profile and an ephemeral debugging port.

Add `--local-phone-flow` to the command above, with a fresh `ROOT`, to run the
local socket cases instead of the four remote cases. The fixture serves
`ROOT/agent.sock`; the local CLI uses `AGENT_KEYRING_SOCKET` and its own receiver
state directory. Its dummy encrypted mirror uses a static fixture key; local
rules use the existing fixture signer. Automatic native prompts are disabled,
and the fixture's local authorizer always refuses without opening a dialog.

The relay's independent TLS system proof uses another isolated directory and
an ephemeral port:

```sh
build/proof/relay-fixture --relay "$PWD/build/proof/relay" --state /tmp/UNIQUE-RELAY-PROOF
```

After stopping the proof, use a `ROOT` whose final component starts with
`relay-proof-` and clear its exact four fixture Keychain services:

```sh
"$SIGNED_WRAPPER/Contents/MacOS/RelayApproverFixture" --erase-dummy-checkpoints "$ROOT"
trash "$ROOT" "$SIGNED_WRAPPER"
```

The cleanup touches only non-synchronizable dummy services, never the app's
production checkpoint or iCloud Keychain.

## Evidence and limits

Private raw logs and binary hashes are in `.private/proofs/r4-relay-exact/`:
`baseline.log`, `joint.log`, and `joint-final.log`. All builds and executions
were on the mini; existing Developer ID signing happened on the MacBook with
no launch there. `go vet` and builds passed for the extended driver.
The local logs, binary hashes and cleanup evidence are in
`.private/proofs/r4-local-phone/`: `local-fixed.log`, `relay-tls.log`,
`build-and-vet.log`, and `remote-after-fix.log`. Failed pre-fix denial evidence
is retained in `local-before-fix.log` and `local-denial-diagnosis.log`.

The runs were entirely headless. They did not open a window, send native input,
display an authentication dialog or contact the tax agent's Chrome.

Software keys stand in for Touch ID and Face ID. Lock state is injected through
`CredentialSessionLockState`; the actual OS lock detector and Secure Enclave
accessibility are device checks. These joint cases cover remote CLI requests
and actual local `agent.sock` routing and outcome reporting.
Physical-phone networking, Apple push, hardware authentication and the actual
approval views remain separate device checks.

## Cleanup

All proof processes exited. Each browser removed its temporary profile. The
signed fixture cleared each run's exact dummy Keychain services; a second
cleanup returned item-not-found for every service. The proof roots, mini
checkout/builds, transferred archives and local signing wrappers were trashed.
No new fixture crash report was present. The mini had no installed app or
registered credential-provider extension afterwards; the MacBook still listed
only its installed 0.2.5 extension. Other agents' processes and data were untouched.
