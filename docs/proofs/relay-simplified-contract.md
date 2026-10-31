# Relay after contract simplification

Written by AI on 2026.10.31 by model gpt-6.1-sol.

The real relay subprocess and scripted TLS approver/receivers pass these checks
with dummy data. No service, installed app, real credential or tailnet policy
is changed.

```sh
devenv shell -- go build -o /tmp/keyring-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-relay-proof ./script/relay_fixture
/tmp/keyring-relay-proof --mode proof --relay /tmp/keyring-relay
/tmp/keyring-relay-proof --mode phone-approval --relay /tmp/keyring-relay
/tmp/keyring-relay-proof --mode idle --relay /tmp/keyring-relay
```

Observed:

- Authenticated enrolment is approved through a rule-owner-signed configuration.
  An added approver binds that configuration's revision and exact digest.
  Non-owners cannot publish it. Exact publication resends succeed; changed
  contents at the same revision conflict.
- A newer unrelated snapshot preserves an Automatic lease signed under the
  preceding revision. Withdrawing machine Automatic permission, changing its
  signing key, or changing Automatic to Ask revokes that Automatic lease while
  preserving a HUMAN-approved lease on the same machine. Blocked policy and
  machine removal revoke affected leases. Removed machines cannot make calls.
- Approve, Deliver, release and SIGKILL/restart preserve exact delivery bytes
  and the original deadline. Late approvals and accepted approval resends
  cannot reopen revoked or released leases. Receiver operation methods and
  relay operation storage are gone.
- DismissEnrolment is unsigned, pinned-approver-only and idempotent. A dismissed
  machine gains no access. ClearDenial clears suppression, preserving terminal
  denials and Blocked policy.
- Ending a lease removes the sealed upload and escalation immediately. The
  retained decision contains no bundle or queued phone answer. The retry hash
  still acknowledges the exact original upload after release or expiry.
  Signed denial reply evidence is retained for receiver verification.
- Lease history and all aliases have a deadline seven days after the end;
  pending enrolment/pairing rows have a ten-minute deadline. To exercise those
  horizons without waiting days, the fixture stops its relay and ages only its
  isolated SQLite deadline columns. After restart, with no RPC driving expiry,
  the timer deletes history and aliases, finishes connected setup streams as
  EXPIRED, deletes setup rows and preserves pinned approver identities.
- The idle proof starts the actual relay with an open WatchWork stream and
  its APNs worker, then leaves it alone for 62 seconds. SIGQUIT records a Go
  runtime dump and exits. The watcher, deadline scheduler and push worker each
  report `select, 1 minutes`: none resumed periodically. The fixture prints the
  trace path. Short signed deadlines in the ordinary proof still wake both
  receiver and approver streams without polling.
- The phone proof still passes HTTP/2 APNs deduplication, durable consent over
  restart, both PHONE signatures, mismatched-consent refusals, signed denial
  attribution, local mirrors/actions and notification retry/token recovery.

The synthetic CLI server (`script/remote_fixture`) also implements
GetConfiguration and Deliver. Its `automatic-newer-configuration` mode keeps an
old Automatic decision valid under a newer snapshot. The modes
`automatic-rule-withdrawn`, `automatic-permission-withdrawn` and
`automatic-key-withdrawn` withdraw each authority condition separately. These
are stand-ins for the client lane's real CLI proof, not relay authorization.

The integrated Swift phone proof belongs to the phone lane. Physical Face ID,
Apple push delivery and the production service/device checks remain outside
these dummy-data proofs.

On 31 October the normal, non-overlay builds passed after integrating the
completed Go client lane. `go vet` and Darwin/Linux builds passed over
`./cmd/... ./internal/... ./script/... ./gen/...`. The relay, PHONE and real
remote CLI proofs all passed. The latter exercised all four Automatic
configuration modes above.

A fresh real-tailnet run also passed: the Mac mini hosted a temporary relay,
mini-server-1 enrolled through a signed configuration, the same Linux TLS keys
were refused from the MacBook's different Tailscale node, and configuration
removal revoked the Linux client. The temporary listener was stopped afterward.

Repository-wide `go build ./...` and `go vet ./...` still found removed-operation
API references in `developer/authority-proof` and `developer/mac-approver-proof`,
which belong to the parallel Mac adaptation lane; those files were left with
that owner.
