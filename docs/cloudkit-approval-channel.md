# CloudKit approval channel

Written by AI on 2026.10.12 by model GPT-6 Astra.

Container: `iCloud.com.joshpalmer.AgentKeyring`, private database only.
The database implementation creates the two custom zones before first use.
Both record types use the request UUID's `uuidString` as their record name;
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
| ApprovalRequest | ApprovalRequests | notificationTitle | String (`Login approval`) | ordinary |
| ApprovalRequest | ApprovalRequests | notificationBody | String (agent, action, field, account, site) | encryptedValues |
| ApprovalRequest | ApprovalRequests | notificationCategory | String (`AGENT_KEYRING_APPROVAL`) | ordinary |
| ApprovalRequest | ApprovalRequests | notificationInterruptionLevel | String (`timeSensitive`) | ordinary |
| ApprovalDecision | ApprovalDecisions | choice | String (`approve`, `deny`, `blockThisLogin`) | ordinary |
| ApprovalDecision | ApprovalDecisions | devicePublicKey | Bytes (P-256 X9.63) | ordinary |
| ApprovalDecision | ApprovalDecisions | signature | Bytes (P-256 ECDSA DER) | ordinary |

The iPhone must use these same zones and IDs. Decisions contain no copy of
the signed request fields: the Mac verifies against its retained request.
Polling fetches only pending request IDs every two seconds. A push can wake
the next fetch; it cannot approve a request. Unknown, malformed and expired
decisions never authorize release.

## Visible notification contract

The iPhone saves `ApprovalCloudRecords.requestSubscription()`: creation-only
query subscription `agent-keyring-approval-requests-v1` in `ApprovalRequests`.
It sends a visible title and body with category `AGENT_KEYRING_APPROVAL`,
mutable content enabled and content-available disabled. No silent pushes.
The desired keys are `agentDisplayLabel`, `expiresAt`, `notificationCategory`.

CloudKit notification configuration has no time-sensitive interruption-level
property. The out-of-scope iPhone notification service extension must fetch
the record from its push ID, reject expired requests, read `notificationBody`
through `encryptedValues`, and set `UNMutableNotificationContent.interruptionLevel`
to `.timeSensitive`. It registers category `AGENT_KEYRING_APPROVAL` with
`APPROVE` and `DENY` actions requiring device authentication. This gives the
full agent/site/account alert without copying private fields into plaintext
push fields. Without that extension, the visible generic alert remains.

Apple references: [encrypted fields](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues),
[notification modification](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications).

## Deployment limits

The Mac app target has the CloudKit container and service entitlements; the
credential-provider extension does not. Unsigned compilation does not prove
CloudKit access. Configure the container and signed profiles, deploy the
encrypted schema to production, and validate delivery on Josh's devices later.
Encrypted fields must be encrypted from their first creation in the schema.

Every completion attempts deletion of both records, and routing waits for
those attempts before returning. A CloudKit outage can prevent deletion;
cleanup logs a fixed diagnostic without login data. The iPhone must enforce
`expiresAt` even if a record remains after an outage. Expiry is an application
rule, not a CloudKit automatic deletion mechanism.
