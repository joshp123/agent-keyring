# Phone consent through the relay

Written by AI on 2026.10.31 by model gpt-6.1-sol.

This is the scripted proof for R4.3 and R4.6, using the real relay subprocess
and real Go receiver. The phone signer, Mac vault, biometric check and APNs
service are dummy substitutes. It does not prove a physical notification,
Face ID, locked-screen Mac vault access or the integrated Swift app flow.
There is no Apple push key yet; those device checks remain separate.

Run from the repo's development environment:

```sh
devenv shell -- bash -c '
  go build -o /tmp/agent-keyring-relay ./cmd/agent-keyring-relay &&
  go build -o /tmp/relay-fixture ./script/relay_fixture &&
  /tmp/relay-fixture --mode phone-approval --relay /tmp/agent-keyring-relay
'
```

The fixture launches a relay on a dynamically selected loopback port with its
own temporary state directory, dummy identities and `--loopback-test`.
It starts a TLS HTTP/2 stand-in gateway, writes its CA and a dummy token key,
and passes `--apns-test-gateway` and `--apns-test-ca`. These flags require
loopback-test and a literal loopback HTTPS gateway. There is no Tailscale,
service, keychain, phone, signing-account or policy change.

Observed checks:

- Bootstrap the Mac, enrol a receiver, publish its signed configuration, compare and
  add a PHONE key, and add a MAC_DELIVERY key without a pairing/TLS identity.
- Refuse receiver/Mac registration of a phone token, a phone escalation,
  an un-escalated phone answer, and phone attempts to deliver credentials.
- Make one remote request, escalate it twice and get one generic notification
  at the sandbox gateway. The gateway independently checks the ES256 JWT
  signature, issuer, key ID, issued time, HTTP/2, device-token path, topic,
  alert/priority, stable collapse ID and original request expiry.
- Read the exact escalated record and MAC source identity from phone work.
  Send phone consent, discard its acknowledgement, SIGKILL/restart the relay,
  retry the same answer and observe the still-PENDING lease. Reconnect the Mac
  and get the identical signed answer. No second notification is sent.
- Have the Mac seal the dummy login under the original phone deadline. Refuse
  valid PHONE and MAC_DELIVERY signatures used as HUMAN. Commit the actual
  PHONE decision, then use the real receiver's `OpenValues` over relay TLS to
  verify and open the dummy login. Release it; an approval retry cannot reopen it.
- The receiver refuses missing/invalid phone consent, different deadline,
  request digest, decision time, lease, choice or reply, invalid outer signature
  and the wrong outer signing role. No changed case opens a value.
- A signed phone denial reply passes through Mac delivery, signed-denial
  storage and the real receiver. An invalid phone signature is refused.
- A non-escalated pending request stays on the Mac. After Mac approval the
  phone sees its active lease, ends it and observes REVOKED; no new delivery
  is allowed.
- For local copies, choose the production gateway, accept plain phone Deny
  without a signature, refuse receiver delivery and phone outcome reporting,
  and queue ClearDenial until the owning Mac reports it. The action survives
  restart. A stale pending snapshot cannot reopen the terminal local lease.
  End Access also queues an owner action and returns the actual last-known
  state until the Mac reports REVOKED.
- Lose a push response after the gateway reads the POST: retry uses the same
  collapse ID, expiry and cached JWT. An inactive-token response removes that
  token and stops attempts; registration recovers the pending notification.

The existing relay proof (`--mode proof`, the default) also checks the release
3 request/approve/deliver/release paths, durable mid-lease restart,
revocation/late approvals and scoped ClearDenial. `prove_remote_cli.py` checks
real CLI program execution, private process delivery, tampering refusals,
denial replies, current Automatic configuration, key-chain advancement and removed
signers. Automatic fixture keys now carry the required MAC_DELIVERY role.
