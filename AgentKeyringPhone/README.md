# iPhone approval core

Written by AI on 2026.10.12 by model GPT-6 (Codex).

The phone uses `AgentKeyringApprovalCore` from the local Swift package. The Mac
uses the same records, canonical byte encoding and CloudKit record mapping.

On launch the app creates or loads its persistent Secure Enclave P-256 key.
The access-control flags are `.privateKeyUsage` only, with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The screen shows SHA-256 of the
X9.63 public key bytes as a full hexadecimal fingerprint. There is no software
key fallback; Secure Enclave behavior requires a physical phone.

The app registers visible remote notifications for category
`AGENT_KEYRING_APPROVAL` and saves the creation-only query subscription in
`ApprovalRequests`, in the private database of
`iCloud.com.joshpalmer.AgentKeyring`. Approve, Deny and Block this login all
require device authentication, without opening the app. Unlock is required
because all three choices must be signed with the protected key.

The response handler validates the CloudKit notification source, fetches the
full request (including encrypted site and account), decodes it with the
shared mapping, and checks expiry. It signs the shared canonical bytes using
P-256 ECDSA with SHA-256 and writes a DER signature with X9.63 public key bytes
to `ApprovalDecisions`, using the request UUID as the record name.
The Mac still verifies against its own retained request and paired-device store.

The screen shows iCloud and notification status, the fingerprint, and the last
20 decisions with time, choice and upload result. “Sent” means CloudKit accepted
the decision; it does not claim that the Mac released a credential. The local
property-list history contains no request IDs or login fields. Failures are
logged with a fixed operation and reason or platform error domain/code, never
error descriptions, records, keys, signatures, nonces or login fields.

Pairing uses **Add iPhone** in the Mac app and **Pair with Mac** on the phone.
Scan the five-minute QR, compare the full fingerprint on both devices, and
confirm the signed-store save on the Mac. See
[the pairing proof and device steps](../docs/proofs/iphone-qr-pairing.md).
The notification service extension remains out of scope; until it exists,
alerts have the generic visible title and body from the shared subscription.

## Unsigned builds

From the worktree root:

```sh
xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/.build/DerivedData-iOS" CODE_SIGNING_ALLOWED=NO build

xcodebuild -project AgentKeyringPhone.xcodeproj -scheme AgentKeyringPhone \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/.build/DerivedData-Simulator" CODE_SIGNING_ALLOWED=NO build
```

Unsigned builds prove compilation only. After Xcode sign-in and provisioning,
verify on Josh's iPhone: key persistence, CloudKit encrypted-field fetches and
visible pushes, all three lock-screen actions, one unlock without a second
biometric prompt, and a trusted decision accepted by the Mac while locked.
