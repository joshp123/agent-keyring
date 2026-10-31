# Phone copies and delivery with the Mac disconnected

Written by AI on 2026.11.01 by model gpt-6.1-sol.

The real relay and Go receiver passed this proof headlessly on the physical Mac
mini. Scripted Mac and phone peers use synthetic keys and dummy logins. TLS,
SQLite persistence, request streams, copy encryption, decision signatures and
receiver verification are production code. A local HTTP/2 gateway stands in for
Apple push. The relay listens on an ephemeral loopback port in its own temporary
state directory. No app, service, tailnet policy or real Passwords data changes.

## Observed behavior

- Pairing binds the phone encryption key into the compared transcript. A
  publication using the old transcript without that key is refused.
- Only the paired phone fetches its own opaque signed copy. Its work stream
  receives the current copy and subsequent replacements. A password-only update
  reaches the next phone delivery without changing configuration.
- Older updates, conflicting bytes at the same revision, non-Ask or absent
  logins, wrong receiver keys and invalid signatures are refused. The phone
  cannot publish a configuration, key set or copy update.
- While a Mac work stream is connected, it controls escalation. Closing the last
  Mac stream escalates an already pending request immediately. A new request
  with no Mac stream also reaches the phone immediately. Each queues one push
  with the original request's stable collapse ID.
- The phone opens the current copy, seals it to the requesting receiver, and
  signs a HUMAN decision. The real Go receiver opens that delivery. Missing or
  invalid signatures, a MAC_DELIVERY signer used as HUMAN, and a different signed
  deadline are refused by the receiver.
- Dropping a connection before request bytes arrive and losing a reply after
  commit both recover by retrying the same request. There is one lease.
- Losing the phone decision acknowledgement and killing the relay with SIGKILL
  retains the exact copy, signed decision, sealed delivery and original lease
  deadline. Retrying acknowledges that decision without another notification.
  Retrying after release does not reopen the lease.
- A stale copy and an empty current copy both use the signed approval-only
  path. The awake Mac delivers on the original lease.
- Mac-first, phone-first and concurrent decisions each produce one winner.
  Both callers receive the same lease; the losing answer is not accepted.
- Plain unsigned phone denials and signed denials with a reply are terminal
  and attributed to iPhone. The Go receiver verifies the signed denial reply.
- Acknowledging Blocked policy defeats an already prepared phone answer. A
  replacement phone cannot fetch the old phone's copy. Removing the old key
  removes its stored payload and copy-revision marker and refuses further
  access; the replacement receives its own fresh copy.

The existing TLS relay proof and phone approval/APNs proof also passed. Darwin
builds, `go vet ./...` and the Linux amd64 build with `CGO_ENABLED=0` passed.

## Reproduce

Build in the repository development environment:

```sh
devenv shell -- go build -o /tmp/keyring-phone-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-phone-fixture ./script/relay_fixture
/tmp/keyring-phone-fixture --mode phone-copy --relay /tmp/keyring-phone-relay
```

For the headless mini run, copy those two binaries into a temporary directory on
the mini and run the same fixture there. The fixture selects a free loopback
port, prints its isolated state directory, and stops its own relay on exit.
It does not use the phone lane's fixed joint-proof ports.

This proves the mini's side with a scripted phone. It does not prove Secure
Enclave access, one physical Face ID, a real Apple notification, mobile data,
physical lid closure or browser fill. The phone lane owns the joint Swift proof
in `script/relay_fixture/phone.go` and `phone_swift_copy.go`; those files are not
part of this change. The existing Automatic proof exercises real CLI browser
fill separately.

## Contract shared with the Mac and phone

`ApproverKey.encryption_public_key` is a PHONE-only P-256 X9.63 public key. Its
destination ID is lower-case hex SHA-256 of its exact 65 bytes. Pairing appends
one uint32-BE-length-prefixed encryption-key component after the existing exact
key-set component. An absent encryption key leaves the earlier pairing
transcript unchanged. `relaycrypto.PairTranscript` and `CopyDestinationID`
implement those bytes.

The MAC_DELIVERY key signs the exact existing `CopyUpdate` bytes. Each update is
a full replacement for one paired phone destination, including an empty update
to clear it. It must name the current configuration and contain only Ask login
IDs. Revisions increase per destination across configuration changes. An exact
current resend is acknowledged; older or conflicting updates are refused. HPKE
info and AAD are unchanged from the
[Automatic copy contract](automatic-copy-relay.md#sender-contract).

The relay retains one opaque `SignedCopyUpdate` per phone destination. It never
opens it. `GetCopyUpdate` has no destination argument: the pinned phone identity
selects its own copy. Missing copies return NOT_FOUND. `WatchWork.copy_update`
carries the retained signed update and changes. A phone checks the update's
signature, destination and current configuration before opening a selected
login; stale or missing contents keep approval-only available.

Direct phone deliveries use the existing `Decide` with authority HUMAN, the
phone's own signing key, configuration revision zero and no forwarded
`phone_decision`. They require that phone's pinned connection and an escalated
remote Ask lease. The existing PHONE authority still means a Mac delivery key
with attached signed phone consent. The phone gains no rule, key-set or copy
publication authority. The first committed `Decide` wins; an exact retry returns
the stored decision and current lease state.
