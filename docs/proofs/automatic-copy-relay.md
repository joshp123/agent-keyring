# Automatic sign-in with the MacBook sender stopped

Written by AI on 2026.11.01 by model gpt-6.1-sol.

The real relay and CLI completed this proof headlessly on the physical Mac mini,
using its Tailscale address, TLS and Tailscale WhoIs. A short-lived Go fixture
stands in for the MacBook. Each sender command exits before the CLI fills the
browser. All keys, logins, receiver state and Chrome profiles are synthetic and
isolated. No app, service, tailnet policy or real Passwords data is changed.

The website accepted the password and a current two-factor code through real
`agent-keyring lease`, `fill`, `status` and `release` commands in headless Google
Chrome. The receiver retried a completed fill without submitting the form twice.
Neither the password nor the OTP seed appeared in ordinary command output.

Observed checks:

- Fetch Automatic keys before pairing. The same keys arrive on the pairing
  stream whose TLS identity is covered by the compared fingerprint; they remain
  unchanged after pairing and restart.
- Publish an owner-signed configuration and a delivery-key-signed copy, enrol the
  real CLI receiver with Automatic permission, then stop the sender. The relay
  grants a task lease and seals the login to that receiver without a prompt.
- Resend the exact update bytes with a fresh DER signature: acknowledge it and
  preserve the existing delivery. SIGKILL/restart the relay: retain the copy,
  keys, lease deadline and exact sealed delivery, then complete another sign-in.
- Publish a password-only copy update without changing the configuration. On the
  same lease, the next fill uses the new password, with the same deadline and no
  prompt. A two-factor code also succeeds; its seed stays at the source.
- Refuse an older update, different bytes at the same revision, a login absent
  from the configuration, Ask and Blocked logins, a wrong destination and an
  invalid delivery signature. The current password still works afterwards.
- Acknowledge Automatic-to-Ask configuration without a subsequent copy update:
  the stored copy is gone and the existing lease is revoked. A fresh request
  waits for approval. After changing the rule to Blocked, a fresh request is
  refused.
- Restore Automatic and deliver a fresh copy. An empty full replacement removes
  the copy and prevents another delivery even on an active lease. An older
  update cannot restore it. A fresh higher revision restores delivery; release
  ends the task.

The existing TLS relay and phone-approval/APNs system proofs also passed. Darwin
builds, `go vet ./...` and the Linux amd64 build with `CGO_ENABLED=0` passed.

## Reproduce

Build in the repository's development environment:

```sh
devenv shell -- go build -o /tmp/keyring-copy-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-copy-cli ./cmd/agent-keyring
devenv shell -- go build -o /tmp/keyring-copy-sender ./script/relay_fixture
```

Copy those three binaries and these four scripts to a temporary directory on
the mini: `prove_automatic_copy.py`, `prove_cli.py`, `test_login_server.py` and
`check_login_artifacts.py`. They use Python's standard library and the installed
Google Chrome. Run on the mini, with its literal Tailscale IP:

```sh
python3 -u ./prove_automatic_copy.py \
  --relay ./keyring-copy-relay \
  --cli ./keyring-copy-cli \
  --sender ./keyring-copy-sender \
  --listen "$(/run/current-system/sw/bin/tailscale ip -4):0"
```

Port zero selects a free port. The script prints its isolated temporary state
directory, then stops only its relay and headless browser. To run on the build
machine over loopback instead, omit `--listen`; the script adds `--loopback-test`.

This proves the relay and Go receiver path with a stand-in sender. The real Mac
import, Touch ID publication and outbox/lost-ack path have a separate joint Swift
proof. Physical lid closure and the phone-copy path are not asserted here.

## Sender contract

`PublishCopyUpdate` accepts a current MAC_DELIVERY signature over the exact
`CopyUpdate` bytes. It is called over the pinned Mac approver connection. Each
update replaces the entire mini copy, including an empty update to clear it.
The configuration must authorize the relay's exact Automatic signing and
encryption keys. The update names that current configuration revision; its own
revision increases across configuration changes. An exact current resend is
acknowledged; older or conflicting updates are refused.

HPKE uses P-256 / HKDF-SHA256 / AES-256-GCM, with UTF-8 info
`agentkeyring.login-copy.v1`. The AAD is:

```text
uint32BE(destination UTF-8 byte count)
|| destination UTF-8
|| uint64BE(configuration revision)
|| uint64BE(copy revision)
|| login ID UTF-8
```

`internal/relaycrypto.CopyLoginAAD` implements these exact bytes. The existing
`SealedAutomaticLogin` contains a sealed `AutomaticLoginContents`. The relay
retains only the accepted revision and update hash alongside the current login
contents, so deleting a copy does not retain an older encrypted copy update.
