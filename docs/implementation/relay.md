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
lowercase hex SHA-256 of the receiver's X9.63 bytes; use the machine in the rule-owner-signed configuration as the authority,
rather than deriving a recipient or trusting relay labels. Its Automatic
permission is authoritative; the relay display copy is not. Initial and subsequent pairing sets must be signed as the RFC
specifies, including the compared transcript and, for an added approver, the
current signed configuration revision and exact configuration digest.

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

`Deliver` returns the bundle separately in `SealedDelivery`, omitting its
upload attachment from the signed decision. It returns the exact approved
request record, and checks current lease state, recipient, policy, purpose
and fields on every call. Operation retry receipts belong to the receiver;
the relay has no operation methods or operation table.

Enrolled receivers can fetch current signed approver keys, key chains and
`GetConfiguration`. Ordinary methods stay inside `RelayWireRequest.client`;
browser/program execution stays on the receiver. An unpaired key can call
only Enrol, PairApprover and initial ConfirmPairing.

`PublishConfiguration` replaces separate index, machine roster and Automatic
grant publications. The current rule owner signs its exact Configuration bytes.
A higher revision commits the snapshot and revokes affected leases in the same
transaction. An exact resend succeeds; different bytes at the same revision
conflict. Removed machines and missing/Blocked logins lose all pending/active
leases. Automatic-approved leases also end if their rule, machine's Automatic
permission or named signing key is withdrawn. Unrelated revisions leave
Automatic leases working, including decisions made under an older revision.
The signature and revision do not bypass the authenticated pending enrolment:
a newly listed machine must match its compared keys, node and current key set.
`DismissEnrolment` is unsigned, approver-only and idempotent; it grants nothing.

The relay still has no credential-decryption or Automatic-signing key.
`GetAutomaticKeys` and relay-held Automatic login payloads remain unavailable
until the later MacBook-shut slice. Push registration is implemented for phones.

Lease deadlines and retention deadlines are indexed in SQLite. One timer waits
for the earliest deadline; a committed mutation wakes connected streams and
the scheduler. The push worker waits for changes or a scheduled retry, with no
periodic polling. Ending a lease immediately deletes its bundle, escalation,
queued phone answer and push attempts. A hash retains exact decision retry
identity without keeping the upload payload. Signed denial reply evidence stays
with its denied lease. Ended lease metadata and request aliases last seven days;
pending setup records last ten minutes. Local phone display history uses the
same retention, independently of the ephemeral escalation.

## Proofs

```sh
/tmp/keyring-relay-fixture --relay /tmp/agent-keyring-relay
```

This uses a real relay subprocess, isolated database, certificates and loopback
TLS clients. It covers request joining, signed approval, delivery, release,
SIGKILL recovery without extending a deadline, WatchLease and WatchWork,
revocation and late/replayed decisions, denial replies, suppression,
ClearDenial, configuration revocations and authenticated setup.
See [the simplified-contract proof](../proofs/relay-simplified-contract.md) for
retention, idle behavior and replay commands. No installed app is touched.

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

## Phone consent (release 4)

Written by AI on 2026.10.31 by model gpt-6.1-sol.

The relay implements RFC 0006 escalation, phone answers, local outcome mirrors
and APNs notifications. The phone needs no credential import. A phone answer
is durable consent waiting for its originating Mac, not an active lease.

- `EscalateToPhone`: pinned MAC only, exact retained remote record or a matching
  pending local snapshot. Only Ask escalates. The original ten-minute pending
  deadline remains unchanged. Retries retain the original record and owner.
- `AnswerFromPhone`: the paired PHONE connection only, matching digest, lease,
  choice, reply hash and times. Approve and reply-bearing Deny require the
  phone signature; plain Deny is unsigned. Exact retries return the current lease while the escalation is retained.
  Once the lease ends, its queued answer is deleted; ended metadata remains. Other answers cannot replace the accepted answer.
- `WatchWork`: PHONE receives only escalated pending requests (with the source
  MAC key ID and, locally, the snapshot). It also receives the active remote
  lease view for End Access. The originating MAC receives retained phone answers
  until its actual decision commits. A reconnect replays outstanding work.
- Local copies have no receiver operations or bundles. `UpdateLocalPhoneLease`
  accepts only the owner and original digest/scope; stale reports cannot reopen
  leases or change a committed deadline. Local RevokeLease and ClearDenial
  queue durable `LocalLeaseAction` items, acknowledged by the owner's report.
  RevokeLease returns the actual last-known snapshot until that report arrives.
- MAC signs HUMAN, enrolment and key-set changes; the MAC rule owner signs
  index, roster and grants. PHONE only signs phone consent. MAC_DELIVERY has no
  TLS identity and is added through MAC-signed key-set publication without
  pairing. PHONE deliveries and current Automatic grants must name this role.
  Only the previously pinned rule owner may retain a legacy unspecified role.

Shared `internal/relaycrypto/authority.go` exports `Role`, `KeyForRole`,
`ValidateRoles` and `VerifyPhoneDelivery`. The last checks both ECDSA/SHA-256
signatures over the **exact protobuf bytes**, not re-encoded messages, and
requires equal digest, lease, choice, approval time, deadline, reply hash and
UTF-8 reply. The receiver separately verifies its retained request scope,
current enrolment, ciphertext and opened bundle as before. Signed PHONE denial
replies use `Lease.signed_denial`; historical denials have no approval TTL.

### Push configuration

Supply all four flags to enable APNs; omit them to keep phone fetch/answer
working without notifications:

```sh
agent-keyring-relay --listen TAILNET_IP:17443 --state PRIVATE_DIRECTORY \
  --apns-key /configured/private/AuthKey.p8 --apns-key-id KEY_ID \
  --apns-team-id TEAM_ID --apns-topic PHONE_APP_BUNDLE_ID
```

The key is read as PKCS#8 P-256 PEM at startup. Nothing creates an Apple key or
changes its permissions/account. `PushRegistration.apns_production` chooses
`api.push.apple.com` or `api.sandbox.push.apple.com`; it must match the app's
signing environment and the key's permitted environment. The provider JWT uses
ES256 with a 30-minute cache. HTTP/2 and verified TLS are required; redirects
are refused.

The push contains only `aps.alert` ("An agent is asking for a login.") and the
default sound. No account, site, request record, answer or credential goes to
Apple. The collapse ID is the lowercase hex request digest (64 bytes). APNs
expiry is the original pending deadline. The relay records an accepted push
per lease and phone, so escalation retries and relay restarts do not resend it.
An uncertain transport result retries after five seconds with that same
collapse ID. HTTP 429 backs off; 5xx follows Apple's fifteen-minute retry
recommendation, which cannot extend a ten-minute request. Other HTTP refusals
stop retrying and log the status/reason; a fresh phone registration permits
retry of refused attempts. An inactive/bad device token is removed only if it
is still the token used by that attempt.

A crash between Apple's acceptance and the durable acknowledgement can resend
the same collapsed notification. This is not an exactly-once APNs guarantee:
Apple controls delivery and may delay or drop pushes. Fetching on app open
remains authoritative. Already in-flight pushes cannot be recalled after an
answer. No sender can prove a visible notification from a gateway response.

Protocol sources: Apple's [request headers and environments](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
and [response handling](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).
