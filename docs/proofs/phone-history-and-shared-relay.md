<!-- Written by AI on 2026.11.01 by model gpt-6.1-sol. -->

# Bounded phone history and shared Swift relay plumbing

The phone retains completed request and lease history for seven days, matching
Mac and relay history. Pending and active records use their absolute deadlines;
terminal records use their completion time and retain any denial hold-off.
An unacknowledged answer keeps its saved request and associated remote lease
regardless of age. Queued trust-update receipts are outside history pruning.
An old replayed unanswered request retains its original pending deadline.

Loading a checkpoint and committing a change prune eligible history. A single
foreground task sleeps until the next expiry or retention deadline. Outbox retry
wakes exist only while commands remain queued, and stop when the queue drains.
The relay work stream retains its existing reconnect backoff. There is no idle
two-second history scan. No wire contract, approval interface or biometric
policy changes.

Feature now uses RelaySupport's transport, TLS identity construction, framing,
signatures, hashes, transcripts, HPKE sealing and login-copy associated data.
Mac mirror-to-bundle conversion remains in Feature. Mac Keychain storage and
Secure Enclave authorization remain local, including AfterFirstUnlock wrapper
migration; the phone keeps WhenUnlocked storage and its own biometric access.
Feature re-exports shared public names, as it already does for its other shared
targets. LeaseFailure aliases the common error so existing Mac error handling
continues to recognize transport failures.

## Proof on the locked Mac mini

All checks use dummy data; no installation or real credential access occurred.

- Full Swift package build: passed with Xcode beta's toolchain.
- Actual universal Release app build: passed with signing disabled, including
  the universal production Go helper and bundled skill/extension.
- `go vet ./...`: passed through the project's devenv.
- `relay_fixture --mode phone-copy`: passed against the real Go relay.
- `relay_fixture --mode receipts`: passed against the real Go relay.
- `relay_fixture --mode phone --phone-binary ...`: passed with the production
  Swift phone core, including lost answers, SIGKILL/restart, authenticated
  receipts, stale configuration refusal and own-removal persistence. This is
  the current headless phone-removal proof, without the optional legacy binary.
- Two focused Swift checks passed. Reopening a checkpoint with 1,000 old
  completed requests removes them from both dictionaries and disk, preserves
  recent history, a lost answer and an exact queued receipt, then allows pruning
  after acknowledgement. Completed history has no further deadline.

The Mac/phone joint removal driver was attempted but could not start its Mac
peer: `Fixture unavailable: ... status -34018` (missing Keychain entitlement).
The mini reports zero valid code-signing identities. The documented wrapper
requires an existing Developer ID signing identity/profile; the MacBook is
paused and the mini remains locked. No certificate/profile changes or alternate
checkpoint implementation were attempted. This joint proof is **not passed**.
Real Face ID/Touch ID and physical device behavior remain outside these checks.

## Concrete drift removed

The original Mac `RelayEndpoint.permitsResolvedEndpoint` was extracted from git
and executed with Network.framework. A `.hostPort` whose host is explicitly
`.ipv6(IPv6Address("::ffff:100.100.1.2")!)` returned **false**. The consolidated
implementation returns **true**, as the phone already did. Both refuse a mapped
LAN address and default loopback. Native IPv4 Tailscale and Tailscale IPv6 remain
accepted. This distinction needs an explicit IPv6 host: constructing
`NWEndpoint.Host` from a mapped address string normalizes it to IPv4 and hides
the old discrepancy. The committed Swift check covers the explicit case.

## Replay

Use `DEVELOPER_DIR` for the installed Xcode beta. Build with:

```sh
xcrun swift build --package-path AgentKeyringPackage
xcrun swift test --package-path AgentKeyringPackage \
  --filter 'reopeningPhone|macAndPhoneUse'
devenv shell -- go vet ./...
devenv shell -- ./script/build_cli.sh
xcodebuild -workspace AgentKeyring.xcworkspace -scheme AgentKeyring \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/keyring-history-release CODE_SIGNING_ALLOWED=NO build
```

Build the relay and fixture through devenv, then use the replay commands in
[phone-removal.md](phone-removal.md) with the built Swift phone fixture. Run
`phone-copy` and `receipts` with the same Go fixture and relay binaries.
[mac-phone-removal.md](mac-phone-removal.md) documents the signed Mac wrapper
and joint driver; its entitlement requirement still applies.

Private build and execution logs are retained outside git under
`.private/proofs/history-shared/` in the main checkout. The MobileBuildMCP wrapper
also hit an Xcode command-line assertion during the final build attempt; direct
`xcodebuild` is the Release build proof. No global configuration was changed.
