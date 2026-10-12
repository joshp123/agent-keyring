# iPhone approval notification service

Written by AI on 2026.10.12 by model GPT-6 (Codex).

## Josh's device checks

Use a signed installation on the paired iPhone, with the extension's profile
allowing the same CloudKit container and environment as the app and Mac.
On a fresh schema, first follow the [initial setup order](iphone-approval-core.md#signed-device-checks-remaining):
with the phone app closed, send a Mac request and wait for its CloudKit save.
Then open or relaunch the phone app so it saves the mutable-content subscription.
Both apps and the extension must use the same environment; pin `Production`
once the schema is deployed.
Enable notification previews and Time Sensitive Notifications for this check.

1. With the phone locked and the Mac locked or sleeping, request a login from
   an agent. Confirm the notification shows the actual agent and field in the
   title, site and account in the body, and `fill` or `acquire` in the subtitle.
   Repeat for the other action and a different field.
2. Confirm it appears as time-sensitive, including through a Focus that allows
   time-sensitive alerts. Confirm only one alert appears for each request.
3. Expand the notification and approve. Confirm Face ID/device authentication
   is the only presence check, and the waiting Mac operation completes. Repeat
   Deny and Block this login; neither should release a credential.
4. Exercise a record-fetch failure and a fetch held beyond the service
   extension deadline (for example, stop connectivity after push delivery or
   pause the fetch in an attached extension debugger). Confirm the body is
   `An agent is asking for a login. Open to review.`, the title is `Login approval`,
   and the subtitle is empty, with no invented or stale login details.
5. Act on a notification after its request has expired or been deleted.
   Confirm no decision authorizes a credential release. A fetch failure while
   handling an action must also send no signed decision.

Physical push delivery, encrypted CloudKit access from the signed extension,
time-sensitive presentation, fallback at the system deadline, and one-tap
Secure Enclave approval remain unverified until these checks run on the phone.

See the [schema](../cloudkit-approval-channel.md) and
[shared build commands](iphone-approval-core.md#unsigned-builds).
