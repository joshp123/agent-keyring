<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Permission withdrawal receipts

Run headless on the Mac mini, 1 November 2026, with dummy credentials only.
The real relay is a separate process with isolated SQLite state and TLS on an
ephemeral loopback port. The receiver uses production `internal/remote` and
owner-only client state, in a fresh subprocess for each attempt. Mac and phone
signers in this proof are scripted software keys. Actual Swift app integration
and the phone's own-removal proof belong to the Mac and phone integration lanes.
No installed app, relay service, tailnet policy or real credential is changed.

## Reproduce

From a checkout containing this proof:

```sh
devenv shell -- go build -o /tmp/keyring-relay ./cmd/agent-keyring-relay
devenv shell -- go build -o /tmp/keyring-relay-fixture ./script/relay_fixture
/tmp/keyring-relay-fixture --mode receipts --relay /tmp/keyring-relay
```

The fixture chooses separate temporary state and loopback ports automatically.
It kills only the relay subprocess it started. `--state DIRECTORY` can select
an explicit empty directory. It prints no password or TOTP seed.

## Observed

- A real receiver opens an approved dummy login before removal. A TLS courier
  then deliberately serves genuine old signed keys and configuration while
  the owner removes the signing phone. Other devices confirm, but the receiver
  stays pending. The old, unexpired delivery can still open while the removal
  is withheld: this is the explicit incomplete-removal limit.
- The relay emits the exact signed withdrawal on existing receiver and phone
  watch streams. A forged receiver receipt, signed by another TLS identity,
  is refused. The owner verifies returned receipts against original device
  SPKIs and the exact update hash.
- Once the receiver learns removal it durably saves the key set and its
  signed receipt together. The courier drops the receipt acknowledgement
  after the real relay commits it. A fresh receiver process retries the
  outbox and refuses the old phone's valid, unexpired delivery. Replaying the
  old key set cannot restore that authority.
- Ask to Blocked uses the same mechanism. Withholding leaves the receiver
  pending; after saving Blocked, the receiver refuses an old valid Mac
  delivery, including after restart and replay of the older configuration.
- Moving off Automatic creates withdrawal A with a missing receiver receipt.
  Later owner-signed removal B removes that receiver. A and B both remain
  pending while B lacks a remaining phone's signature. Once B's remaining
  device signatures have been independently verified, B completes and A's
  missing requirement can retire. No receipt is invented for the absent device.
- The removed receiver fetches missed configurations in ascending order,
  durably saves its own removal and drains its receipt outbox before refusing
  further use. Removed identities can fetch signed public changes over their
  original node binding, but cannot request logins, fetch copies or answer.
- Killing and restarting the relay preserves exact device-signed evidence.
  The owner publishes a withdrawal and goes offline before collecting the
  phone's confirmation. The fixture ages completion beyond seven days and
  restarts over the previous database schema. The returning owner can still
  fetch and verify both signatures; a read does not start expiry. Only its
  explicit collection acknowledgement, sent after saving the evidence, starts
  retention. A phone, receiver, wrong target hash and incomplete target are
  refused. Retrying after restart keeps the first collection timestamp.
  Aging that timestamp beyond seven days then permits pruning; late receipt
  and collection retries do not recreate evidence. Routine receipts and devices
  outside an update's original required set are likewise ignored, not counted.

The final result is `All relay system checks passed.` The existing relay TLS,
phone approval, phone copy and remote CLI system proofs also passed. Darwin
and Linux builds and `go vet ./...` passed. The existing idle proof checks the
watcher, deadline scheduler and push worker remain blocked for a full minute
after the runtime's GC observation interval; there is no added polling loop.

## What this proves and what it does not

An honest receiver that has saved a withdrawal cannot be rolled back by old
relay data. A withholding courier cannot supply that receiver's signature on
an unseen update, so the Mac must keep that device pending. The relay's ACK
is never the owner's completion evidence.

No receipt proves remote erasure of a lost phone's ciphertext, passwords,
TOTP seeds or an already disclosed value. This proof makes no such claim.
Physical Face ID, Secure Enclave behavior and a lost device's storage are not
tested by software signers.
