<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Phone removal persistence

The actual Swift phone approver passed the full phone system proof on the
physical Mac mini, over loopback TLS with the real relay and Go receiver.
Software keys stand in for Face ID. No phone installation or display was used.

The added removal case proves:

- A verified approver-key advance is saved before a later invalid configuration
  fetch fails. Restarting against an older relay snapshot keeps that advance.
- A phone holding a sealed copy and a signed answer whose acknowledgement was
  lost saves its own verified removal, then refuses further operation. The
  checkpoint no longer contains the copy, configuration or queued answer.
- Serving old signed keys and hiding the removal history cannot restore that
  phone, including across two process restarts. No biometric authorization is
  requested by update processing.

## Authenticated update receipts

The same full proof passed after integrating the relay courier and production
Go receiver receipt changes. The added actual Swift phone cases prove:

- Removing another paired phone produces no receipt while the phone is offline.
  Reconnection saves the owner-signed keys and exact receipt body together.
  Go independently verifies the resulting signature with that phone's TLS SPKI.
- A forged receipt naming the phone but signed by another TLS identity is
  refused. The payload hash excludes the signed update's signature wrapper.
- Dropping the receipt acknowledgement, then SIGKILLing the phone process,
  leaves its exact signed receipt queued. Restart resends those same bytes and
  drains the outbox without biometric authorization.
- Two missed Ask-to-Blocked configuration withdrawals, followed by a newer
  refresh, each receive a receipt for their own exact snapshot. The phone saves
  them individually, rather than acknowledging only the newest revision.
- A deliberately injected older live `WatchWork` snapshot with an unseen hash
  neither changes the saved configuration nor produces a receipt. A subsequent
  ordinary request reaches the same stream and a plain denial works.
- An honest relay's removed-identity access lets the phone fetch its own removal.
  The subsequent stale-relay and restart check still leaves it removed.

The Release iOS app also built with `CODE_SIGNING_ALLOWED=NO`. This verifies SDK
compilation, not device signing, Face ID or physical erasure. No build was
installed. The phone views are unchanged.

The integrated run used phone source `a3ccaa6`, shared support `6b8b564`, and
own-removal source `0660163`; relay source `8f330a6` and `78bb356`; production Go
receiver source `4075a7c`; contract `fde9fac`. The log ends with
`All relay system checks passed`. Private evidence is:

- `.private/proofs/phone-removal/phone-receipts-joint.log`
- `.private/proofs/phone-removal/phone-receipts-swift-build.log`
- `.private/proofs/phone-removal/phone-removal-ios-summary.log`
- The complete `build_device_*.log` alongside those files.

The fixture changes only its stopped relay database to reproduce stale courier
state. It never edits the phone checkpoint. This is cooperative local deletion;
it makes no claim that removing a different or lost phone erases its ciphertext.

Replay from the repository on a Mac, using Xcode's Swift toolchain:

```sh
swift build --package-path AgentKeyringPackage --product agent-keyring-phone-fixture
go build -o /tmp/phone-removal-relay ./cmd/agent-keyring-relay
go build -o /tmp/phone-removal-fixture ./script/relay_fixture
/tmp/phone-removal-fixture --mode phone --relay /tmp/phone-removal-relay \
  --phone-binary "$PWD/AgentKeyringPackage/.build/debug/agent-keyring-phone-fixture"
```

The optional `--legacy-phone-binary` flag also exercises upgrade from the genuine
approval-only phone fixture built from the earlier release. The recorded run
included that flag. Private logs are in `.private/proofs/phone-removal/`.
