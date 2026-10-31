# Ask login copies from the Mac

Written by AI on 2026-11-01 by model gpt-6.1-sol.

The production Swift Mac sender and import path passed the headless proof on the
physical Mac mini against the real Go relay and an independent Go phone receiver.
The receiver uses software signing/sealing keys; this checks the Mac's bytes and
durability without substituting a Go sender for the Mac. It does not claim the
phone app's Face ID or Secure Enclave behavior.

Mac source: `4710e5d`. Relay contract: `3146922` (here `16c3a84`); relay source:
`57bf9cd` and `9329354` (here `31af9c6` and `e177097`).

The proof checked:

- Swift and Go independently compare the phone's signing, TLS and sealing keys.
  The old fingerprint without the sealing key is refused before authorization.
  The next signed key set binds that exact transcript and sealing key. The first
  copy queues behind the key set under pairing's single authorization.
- With separate Ask, Automatic and Blocked dummy logins present together, only
  Ask reaches the phone. The receiver verifies the current MAC_DELIVERY signature,
  configuration revision, destination, HPKE AAD and contents: account, password,
  sites and TOTP seed/parameters. Fetch and WatchWork backlog return the exact
  retained signed copy.
- A synthetic Apple exchange enters `MirrorAppModel.receive`, the production
  mapper, merger, encrypted mirror save and import handler. The selected Ask
  password changes, the other two logins remain, and both copy destinations get
  one background signature each. The signed configuration stays byte-for-byte
  unchanged and human authorization count does not increase.
- A transparent TLS proxy lets the mini-copy acknowledgement through, then loses
  the phone-copy acknowledgement after commit. Applying stays visible. Killing
  and restarting both Mac fixture and relay preserves the exact signed update,
  ciphertext and destination revision. Resend clears Applying without another
  authorization, signature or encryption.
- Ask to Automatic replaces the phone's copy with an empty list. Automatic to
  Ask restores the refreshed password. Blocked clears it. Destination revisions
  increase across these configuration changes.
- An approval-only phone with no sealing key still pairs using the original
  transcript and receives no password copy.

The existing Automatic-copy proof passed again after sharing its sender with the
phone path. It still checks password refresh on the same lease, fixed deadline,
lost acknowledgement and both restarts, and removal/revocation on rule changes.
The Mac Swift product build and `go vet ./...` passed. Logs are retained locally
under `.private/proofs/round10/`.

## Repeating the proof

Use the existing Developer ID profile to sign a mini-built Swift fixture wrapper,
as in [the Mac approver proof](mac-relay-approver.md). Never launch that wrapper on
the MacBook. Build the relay and driver from the same tree. With unused loopback
ports 17445 and 17455, run on the mini:

```sh
mac-approver-proof --phone-copy-updates \
  --root "$HOME/Library/Containers/com.joshpalmer.AgentKeyring/Data/relay-proof-r10p1" \
  --approver "$SIGNED_WRAPPER/Contents/MacOS/RelayApproverFixture" \
  --relay "$RELAY_BINARY"
```

Use a fresh, short `relay-proof-` directory name: the Unix socket path inside it
must fit macOS's `sockaddr_un`. The driver stops its processes. Erase only that
root's isolated, non-synchronizable checkpoint items using the fixture's
`--erase-dummy-checkpoints` option, then move the proof roots and binaries to
Trash. Leave the installed app, its state and the service relay untouched.

No screen, native input, app installation, Apple Passwords or real credentials
were used. Actual Apple export and hardware authentication remain device checks;
the phone lane owns the production phone-core and direct-delivery proofs.
