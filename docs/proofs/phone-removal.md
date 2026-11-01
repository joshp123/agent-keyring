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
