# Import identity and save reporting

Written by AI on 2026-10-31 by model gpt-6.1-sol.

## Scope

Headless checks on the Mac mini, with synthetic credentials in temporary directories.
No Apple Passwords export, Touch ID, installed-app replacement or screen interaction.
The tests feed Apple's credential-exchange data types through the production mapper,
merger, encrypted store and import handler. Rule checks use software signing keys.

## Identity and rules

Astra's original reproducer compiled directly against `MirrorModels.swift` and
`SnapshotMerger.swift`. Before the fix, its different source ID, case-distinct
account and changed secondary destination reused the original login ID and
removed the original item. After the fix, on both Macs:

```text
Old login ID reused: false
Original source item retained: true
Result count: 2
```

The committed tests independently check:

- A different exporter, Apple account ID or Apple item ID creates a new Ask login
  and retains the original login and its Automatic rule.
- A case-distinct username on the same source item gets a new login ID and Ask.
- A changed secondary destination on the same source item gets a new ID and Ask.
- A password-only refresh keeps the login ID and Automatic, even with an unchanged
  modification timestamp. Reordering the same destinations also keeps the rule.
- A password-only refresh leaves the published authorization contents unchanged;
  adding a login requires confirmation. Comparison uses the persisted configuration,
  so an old generation-based digest does not force an upgrade confirmation.

## Saved mirror and reporting

The mini refreshed one login in an encrypted two-login dummy mirror through
`MirrorAppModel.importCredentials`. The refreshed password kept its ID and the
unrelated login survived unchanged after reload.

Real filesystem failures cover both sides of the commit:

- Preventing atomic replacement of `current` leaves the old mirror and status
  intact, with an import-failure notice.
- Preventing old-generation enumeration or removal still returns a successful
  save, with the new mirror and metadata readable. A later save retries cleanup.
- An unavailable authority after a committed import updates the displayed status
  and says the logins were saved, with a separate recovery notice. It never says
  the existing mirror was unchanged.

Replay the focused checks from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path AgentKeyringPackage \
  --filter 'SnapshotMergerTests|EncryptedSnapshotStoreTests|MirrorImportFailureTests'
```

The mini passed all 17 tests in the three suites, including both publication cases.
Original logs are retained locally under `.private/proofs/round8/`:
`import-tests.log`, `publication-tests.log` and `reproducer.log`.

## Removing the unused keystroke filler

Repository search found no production construction of `AgentCredentialFillProcessor`.
The active `MirrorAgentRequests` socket handler returns approved values to the Go
receiver, which uses Chrome's debugging connection. The old XPC client, native
keystroke service, Accessibility onboarding and their support module/tests were
removed. SwiftUI accessibility labels and the live Go receiver were not changed.

A fresh, unsigned Release app built on the mini from `1169be0`, using the isolated
identifier `com.example.keyringround8.AgentKeyring`. It was never launched.
The build used `mobilebuildmcp macos build`, the normal workspace and scheme,
an isolated derived-data directory, `CODE_SIGNING_ALLOWED=NO` and
`AGENT_KEYRING_BUNDLE_ID_PREFIX=com.example.keyringround8`.

Inspection of that app found no filler bundle, old filler symbols,
`AXIsProcessTrusted` call, `CGEventPost` call or Accessibility settings route.
The credential-provider extension and universal Go CLI remain bundled. The CLI's
SHA-256 matched the binary built from this tree:

```text
872b127b5869e2fed60a3dd6dd033f4095535610a68b8f9ebd0648dce306e269
```

`app-build.log` is retained beside the import logs. This proves compilation and
the shipped code/bundle contents; it is not a new GUI or Apple export acceptance run.
