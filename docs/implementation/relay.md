---
written_by: AI (gpt-6.1-sol, 2026-10-31)
---

# Release 3 relay

`cmd/agent-keyring-relay` implements RFC 0005's relay and enrolment server.
It stores protobuf records and opaque sealed deliveries in one SQLite database,
with WAL and full synchronous commits. A response is sent only after its
transaction commits. TLS keys, the database and its directory have owner-only
permissions.

## Run in isolation

Build with the repository's pinned development environment (Go 1.26):

```sh
devenv shell -- go build -o /tmp/agent-keyring-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-relay-fixture ./script/relay_fixture
```

The normal executable requires a literal Tailscale listen address. It refuses
wildcards, LAN and public addresses. Each connection uses TLS 1.3, proves
possession of its TLS private key, and is checked through the local Tailscale
CLI's `whois --json`. Authorization binds the pinned SPKI to the observed stable
node ID; copying the key to another node does not work. The Tailscale executable
must be able to reach the daemon as the relay's user.

For a controlled, dummy-only loopback session, use two processes:

```sh
# Choose a new empty directory for each independent fixture run.
/tmp/agent-keyring-relay --listen 127.0.0.1:17443 \
  --state /tmp/keyring-example/relay --loopback-test

/tmp/keyring-relay-fixture --mode approver --address 127.0.0.1:17443 \
  --state /tmp/keyring-example/approver
```

The fixture pairs a fresh signing key, publishes `fixture-login` for
`https://example.com`, and signs fixture enrolments and lease decisions. It
HPKE-seals dummy username/password contents to each enrolled receiver. It prints
setup fingerprints, recipient IDs and lease IDs, never a credential value.
This fixture **automatically approves requests**: use only its isolated relay,
never a real keyring. Its signer is intentionally fresh on every invocation;
restart the entire fixture with a new empty state directory.

For a tailnet session, copy the built relay to a temporary directory on the
relay host and run:

```sh
/tmp/keyring-example/relay --listen TAILSCALE_IP:17443 \
  --state /tmp/keyring-example/state --tailscale /absolute/path/to/tailscale
```

Point the fixture approver and the client at `TAILSCALE_IP:17443`. Omit
`--loopback-test`; that switch is restricted to loopback and substitutes a
synthetic node identity only for local system checks. No service or tailnet
policy is configured by this binary.

## Shared bytes

`internal/relaycrypto` is shared with the receiver. It provides SPKI-pinned TLS
client configurations, explicit setup-only SPKI observation, P-256 signature
verification, and the RFC transcript and digest functions.

- `ClientConfig(tls.Certificate, pinnedSPKI)` refuses a missing pin and compares
  the exact peer SPKI DER. DNS and CA roots do not replace this pin.
- `ObservingClientConfig` exposes the observed relay SPKI only during setup.
  The caller binds it into the local fingerprint comparison before trusting it.
- `EnrolTranscript(relaySPKI, clientSPKI, receiverX963, exactKeySet)` and
  `PairTranscript(relaySPKI, approverSPKI, signingX963, exactKeySet)` encode
  **each** component with a uint32 big-endian byte length. The first component
  is the domain, including its trailing NUL. Empty components still have a
  four-byte zero length. Domains and order are specified in `relay.proto`.
- `Fingerprint(transcript)` takes the first 16 SHA-256 bytes, uppercase hex,
  eight four-character groups separated by one ASCII space.
- `Digest(domain, record)` hashes `domain UTF-8 || NUL || exact record bytes`.
  Pass the domain **without** its NUL; this differs from the transcript encoding.
- Signatures use ECDSA P-256, SHA-256 of the exact signed protobuf byte string,
  DER signature encoding. Public signing/receiver keys use uncompressed X9.63;
  TLS keys use SPKI DER.

Byte-only vectors for another language (the short components are illustrative
bytes, not valid public keys): relay SPKI `01`, peer SPKI `0203`, receiver or
signing key `04`, current key set empty.

| Transcript | SHA-256 | Fingerprint |
| --- | --- | --- |
| Enrol | `da37bee0a8442099772e291300e0752705cdc00afc52471ac7df798eb5c86629` | `DA37 BEE0 A844 2099 772E 2913 00E0 7527` |
| Pair | `0ef0ef6bd48f8e2eded9fee5f7e1b1ccb171e70967fa7bf0b93d14198718e481` | `0EF0 EF6B D48F 8E2E DED9 FEE5 F7E1 B1CC` |

## What the client and Mac approver must match

The relay issues recipient IDs and receiver key IDs. The receiver key ID is
lowercase hex SHA-256 of the receiver's X9.63 bytes; use the returned signed
record as the authority, rather than deriving a recipient or trusting labels.
The enrolment decision's Automatic flag is authoritative; its relay display
copy is not. Initial and subsequent pairing sets must be signed as the RFC
specifies, including the compared transcript and, for an added approver, the
current signed roster.

The approver should retain exact request/enrolment/key-set bytes. The relay
returns them unchanged. Sign `DecisionStatement` over the request's
`agentkeyring.request.v1` digest; bind the reply SHA-256 even when empty, the
recipient, receiver key ID, absolute deadline and ciphertext SHA-256. Upload the
bundle in `SignedDecision.bundle`. The relay stores that upload, decision and
lease transition atomically. Retransmit the same decision after a lost ack.
Exact accepted resends succeed even after expiry; a different decision gets an
ack with `accepted=false` and the current lease. It never reactivates the lease.

Plain Deny uses `authority=APPROVER_CONNECTION`, DENY, an empty reply and no
signature/bundle, over the pinned approver connection. Other uses of that
authority are refused. A HUMAN-signed denial with a non-empty reply is returned
in every lease snapshot and decision acknowledgement as `Lease.signed_denial`:
its exact decision and request bytes, with no bundle. Plain Deny leaves this
unset. A new request suppressed by an earlier denial has no copied reply or
proof: the earlier signature names the earlier lease.

`ClearDenial(recipient_id, login_id)` is unsigned and accepted only from a
pinned approver connection. It clears all suppression deadlines for that pair,
including suppressed follow-up requests, without changing any denied decision
or signed reply. It is idempotent and durable. A fresh request must still get
its own decision; retrying an old request ID still returns its denied lease.
Clearing suppression does not change Blocked policy.

`WatchWork` also emits `ApproverWork.lease`: current pending and active leases
on connection, followed by changed snapshots, including terminal transitions
for leases already shown. A reconnect rebuilds the current pending/active view.
The existing pending-request records and cancellation notices remain separate
work items. Lease snapshots carry signed denial reply proofs when applicable.

`RevokeLease(lease_id)` is unsigned and accepted only from a pinned approver
connection. It atomically persists REVOKED before acknowledging. Terminal
leases return unchanged, including on retries and after restart. A late
approval cannot reactivate a revoked pending lease; an exact resend of a
previously accepted approval returns its current revoked state. No further
bundle is delivered. The response uses top-level `RelayWireResponse.lease`.

`BeginOperation` returns the bundle separately in `SealedDelivery`, omitting
its duplicate upload attachment from the signed decision. It returns the exact
approved request record. A known operation key returns `already_started` and
no bundle, including after restart or release. A missing outcome means
Uncertain. `FinishOperation` can record an existing action after lease expiry
or release; contradictory finishes conflict.

An unpaired key can call only Enrol, PairApprover and (before first setup is
committed) ConfirmPairing. A paired approver cannot use receiver methods.
Enrolled receivers can fetch current signed approver keys, key chains,
Automatic grants and the signed index. Their ordinary methods stay inside
`RelayWireRequest.client`; browser/program execution remains on the receiver.
Every stream rechecks enrollment as it emits state, so revocation also ends
existing streams.

Publish the signed login index after import or rule changes, and the signed
machine roster after enrolment/revocation (including an empty roster). Roster
omission revokes machines and leases; replaying their old approval does not
restore them. Signing an Automatic grant does not override a machine's
Automatic opt-in. Grant changes revoke active Automatic leases. Current rules
are checked before every new delivery.

`GetAutomaticKeys`, `PublishAutomatic` and `RegisterPush` are release 4 methods
and return an explicit unavailable-method error here. The release 3 relay has
no credential-decryption or Automatic-signing key. The Mac remains responsible
for both human and delegated Automatic approval.

## Proofs

```sh
/tmp/keyring-relay-fixture --relay /tmp/agent-keyring-relay
```

This starts an actual relay subprocess with its own database, certificates and
loopback TLS clients, then kills/restarts it mid-lease. It checks pairing,
enrolment, role restrictions, request joining, changed retry IDs, invalid
signatures, signed approval, begin/finish/release, unchanged deadlines,
Uncertain operation retry, next-step delivery, WatchLease reconnect, a short
signed expiry, resend after expiry, cancellation, policy revocation, denial
suppression, Automatic grants and machine opt-in, wrong recipient, signed
roster revocation, added approver pairing, key-chain fetch, connection-authenticated
plain denial restrictions, signed denial reply proofs in all lease responses,
scoped ClearDenial across a restart, followed by a new approval, and Blocked
policy after clearing suppression. It checks approver lease backlog, updates,
expiry, denial proofs and reconnect, then revokes pending and active leases,
including late approvals and exact accepted-decision resends before and after
restart. It retains the
fixture directory it prints for inspection. It does not touch installed apps.

The real-tailnet enrolment proof needs the relay already running with a fresh
empty database on a tailnet host and the fixture cross-built for Linux:

```sh
devenv shell -- env GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go build -o /tmp/keyring-relay-fixture-linux ./script/relay_fixture
# Copy the Linux binary into a temporary directory on the Linux proof host.
/tmp/keyring-relay-fixture --mode tailnet --address RELAY_IP:17444 \
  --linux LINUX_SSH_HOST --remote-binary /tmp/UNIQUE/fixture
```

The controller runs the Linux fixture through SSH, signs its enrolment, copies
only its fixture TLS keys to the controller's different tailnet node, checks
refusal there, then revokes the machine and checks refusal from Linux.

On 31 October 2026 these checks passed against the physical Mac mini relay and
a Linux tailnet node, using the real Tailscale daemon. Only temporary binaries,
fixture keys and state were used. No service, access rule, installed app or real
credential was changed. Loopback proofs and `go vet` also passed.

These are relay proofs. They do not establish Mac app outbox behavior,
Touch ID, physical setup-code comparison or a real website sign-in. Those
remain the Mac/client integration and release device proofs in RFC 0005.
