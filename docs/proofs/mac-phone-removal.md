# Removing an offline phone from the Mac

Written by AI on 2026.11.01 by model gpt-6.1-sol.

`RelayApprover.removePhone(_:context:)` removes a named PHONE key under one
owner authorization. The phone can be offline. The signed key set, removal of
unsent copies to that phone, this Mac's local application and TLS receipt, and
the original remaining-device evidence are saved in the same authority
checkpoint. The existing outbox sends the signed change and receipt, and
retries without another authorization.

The public `withdrawals` collection is included in `RelayApproverUpdate`.
Each `RelayPermissionWithdrawal` names the exact update kind and revision,
contains its device labels and statuses, and exposes `isComplete`.
`RelayPermissionDeviceStatus.confirmed` means this Mac verified that original
TLS identity's signature for the exact payload hash. `removedByLaterChange`
means a later, fully confirmed owner withdrawal retired its missing obligation.
A device with neither flag is still waiting. `isApplying` stays true while
publication or any required confirmation remains pending. The Machines screen
can therefore show which devices applied removal and which are still waiting.
The designer owns the views and their adapters.

The same mechanism records configuration withdrawals, including Automatic
permission, login destinations and receiving-machine removal. A later change
never rewrites an earlier required-device set. A durable sequence orders changes
made within the same second; only a later withdrawal with all of its own receipts
can retire an earlier missing device. Pending evidence survives indefinitely;
completed evidence is retained for seven days, including any evidence still
needed by another record. Retention shares the existing deadline timer.

The Mac independently verifies receipts. A relay acknowledgement or its claim
of completion is insufficient. Only previously saved owner publications can
be acknowledged by this Mac; courier input never replaces its rules.

## Joint proof

The headless proof passed on the physical Mac mini using the production Swift
Mac approver, two production Swift phone cores, the real Go relay, and fresh
processes running the production Go receiver. Software signing keys substitute
for Touch ID and Face ID. No browser, native input, installation, running service
or real Passwords data is involved.

- The first phone receives an Ask copy and supplies a password/TOTP delivery
  which a fresh production receiver successfully opens without printing values.
  That phone then exits before removal.
- One Mac authorization removes only that phone. All other approver keys and
  the exact configuration remain unchanged. The relay deletes its retained copy.
- A lost publication acknowledgement, Mac restart and relay restart preserve
  the exact queued signed change and its pending receiver evidence.
- The remaining phone confirms automatically. The offline receiver remains
  explicitly pending despite the relay acknowledging publication.
- A forged receiver receipt inserted into the courier's own isolated database
  reaches the actual Swift Mac and is rejected. It cannot complete removal.
- Fresh production receiver processes learn and save removal, publish their
  authentic receipt, and reject the old phone's still-unexpired delivery.
  The Mac then completes the change without another authorization.
- The retired connection cannot decide or fetch a new copy. A genuine synthetic
  password import sends nothing to its old destination and asks for nothing.
- An Ask-to-Blocked change A stays pending. A later receiving-machine removal B
  also stays pending while the remaining phone is offline; B's publication ACK
  does not retire A's absent receiver. Both restarts preserve that state. Only
  the remaining Swift phone's real receipts complete B and then retire A's
  missing receiver. Public updates require no phone authorization.

The complete Swift package and `go vet ./...` pass. The actual Xcode Release
app builds on the mini, with its universal Go helper. It is not launched or
installed by this proof. Logs are retained in `.private/proofs/round12-removal/`.

Build/sign the mini-built Mac fixture using the existing profile as described
in [the Mac approver runbook](mac-relay-approver.md). It has no extension and is
never launched on the MacBook. Build the relay, driver and phone fixture from
the integrated committed tree. With unused proof ports 17445 and 17455, run:

```sh
mac-approver-proof --phone-removal \
  --root "$HOME/Library/Containers/com.joshpalmer.AgentKeyring/Data/relay-proof-UNIQUE" \
  --approver "$WRAPPER/Contents/MacOS/RelayApproverFixture" \
  --relay "$RELAY_BINARY" --phone-binary "$PHONE_BINARY"
```

The driver stops its processes. Erase only the root's isolated, non-synchronizing
checkpoints with `RelayApproverFixture --erase-dummy-checkpoints "$ROOT"`, then
trash the root and proof build. Do not change the installed app, CLI links or
`/var/db/agent-keyring-relay`.

Real Touch ID and the removal screen still need the device session. An offline
or compromised phone's previously stored password/TOTP copy is not remotely
erased. The receipt proves authenticated application of public permissions,
not deletion of plaintext or instant propagation to an offline device.
