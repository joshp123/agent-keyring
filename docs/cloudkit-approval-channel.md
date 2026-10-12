# CloudKit approval channel

Written by AI on 2026.10.12 by model GPT-6 (Codex).

Container: `iCloud.com.joshpalmer.AgentKeyring`, private database only.
The database implementation creates custom zones before first use.
Approval records use the request UUID's `uuidString` as their record name;
zones distinguish their IDs because CloudKit IDs are unique within a zone.

| Record | Zone | Field | CloudKit value | Storage |
| --- | --- | --- | --- | --- |
| ApprovalRequest | ApprovalRequests | agentDisplayLabel | String | ordinary |
| ApprovalRequest | ApprovalRequests | field | String (`password`, `totp`, or `username`) | ordinary |
| ApprovalRequest | ApprovalRequests | action | String (`fill` or `acquire`) | ordinary |
| ApprovalRequest | ApprovalRequests | oneTimeValue | Bytes (32 bytes) | ordinary |
| ApprovalRequest | ApprovalRequests | expiresAt | Int64 (Unix seconds) | ordinary |
| ApprovalRequest | ApprovalRequests | site | String | encryptedValues |
| ApprovalRequest | ApprovalRequests | account | String | encryptedValues |
| ApprovalDecision | ApprovalDecisions | choice | String (`approve`, `deny`, `blockThisLogin`) | ordinary |
| ApprovalDecision | ApprovalDecisions | devicePublicKey | Bytes (P-256 X9.63) | ordinary |
| ApprovalDecision | ApprovalDecisions | signature | Bytes (P-256 ECDSA DER) | ordinary |
| PairingRequest | PairingRequests | publicKey | Bytes (P-256 X9.63) | ordinary |
| PairingRequest | PairingRequests | deviceName | String | encryptedValues |
| PairingRequest | PairingRequests | authenticationCode | Bytes (HMAC-SHA256) | ordinary |

The iPhone must use these same zones and IDs. Decisions contain no copy of
the signed request fields: the Mac verifies against its retained request.
Polling fetches only pending request IDs every two seconds. Temporary fetch
failures are retried until expiry; not-authenticated and quota-exceeded end
the phone route. Unknown, malformed and expired
decisions never authorize release.

## Visible notification contract

The iPhone saves `ApprovalCloudRecords.requestSubscription()`: creation-only
query subscription `agent-keyring-approval-requests-v1` in `ApprovalRequests`.
It sends a visible title and body with category `AGENT_KEYRING_APPROVAL`,
mutable content enabled and content-available disabled. No silent pushes.
No record fields are copied into the push; the extension fetches by record ID.

CloudKit notification configuration has no time-sensitive interruption-level
property. The iPhone notification service extension fetches the full record from its
push ID and rejects malformed or expired requests. It decodes site and account
through `encryptedValues`, builds the title, body and subtitle from the same
`ApprovalSignedFields` used for signing, and sets
`UNMutableNotificationContent.interruptionLevel` to `.timeSensitive`.
The title is `<agent> wants your <field>`, the body is `<site> · <account>`,
and the subtitle is `fill` or `acquire`. Notification templates are not stored in request records. Fetch failure or extension timeout returns
`An agent is asking for a login. Open to review.` with no request details.
The action handler resolves the same push record ID and independently re-fetches
the record before signing; it never signs notification text. The phone app registers category `AGENT_KEYRING_APPROVAL` with
`APPROVE`, `DENY` and `BLOCK_THIS_LOGIN` actions requiring device authentication. This gives the
full agent/site/account alert without copying private fields into plaintext
push fields. Without that extension, the visible generic alert remains.

Apple references: [encrypted fields](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues),
[notification modification](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications).

## Deployment limits

The Mac app target has the CloudKit container and service entitlements; the
credential-provider extension does not. The notification service extension has only the app's iCloud container and
CloudKit service entitlements. Unsigned compilation does not prove CloudKit access. Configure the container and signed profiles, deploy the
encrypted schema to production, and validate delivery on Josh's devices later.
Encrypted fields must be encrypted from their first creation in the schema.

Every completion attempts deletion of both records, and routing waits for
those attempts before returning. A CloudKit outage can prevent deletion;
cleanup logs a fixed diagnostic without login data. The iPhone must enforce
`expiresAt` even if a record remains after an outage. Expiry is an application
rule, not a CloudKit automatic deletion mechanism.

## Pairing contract

The QR contains a memory-only 32-byte secret, pairing UUID and five-minute
expiry. The Mac publishes no challenge record. The phone writes the pairing
UUID as its record name in `PairingRequests`; it never uploads the secret.
The HMAC covers the pairing ID, X9.63 public key and verbatim UTF-8 device name,
including the name's plaintext bytes even though CloudKit stores it encrypted.
See `PairingRequest.canonicalBytes` for the v1 wire encoding.

After upload, the phone displays a six-digit code: the first four SHA-256
public-key digest bytes interpreted as an unsigned big-endian integer, modulo
1,000,000, padded with leading zeroes. The Mac requires that code to match its
received key before Touch ID can save it. The authentication reason includes
the received device name and matching code. The signed store contains the
public key, name and pairing time.

The Mac consumes and deletes the first response before offering confirmation.
Rejection, cancellation and expiry end the session and attempt deletion.
Cancellation cleanup runs in a fresh task. Cleanup errors never establish trust
or permit QR reuse. A fresh CloudKit schema must create `deviceName` as an
encrypted field from its first use.

## Device proof

Use the [pairing steps](proofs/iphone-qr-pairing.md),
[approval steps and build commands](proofs/iphone-approval-core.md), and
[notification checks](proofs/iphone-notification-service.md).
