# Agent Keyring privacy policy

Updated: 2026-11-24
Website: https://keyring.opentrawl.sh/privacy/
Source code: https://github.com/opentrawl/agent-keyring

Agent Keyring keeps your passwords on your own devices. There is no account, no vault of ours, and no ad or tracking SDK.

## Passwords and approvals

Your passwords stay encrypted on your own Mac, iPhone and Apple Watch, protected by keys kept in each device's Secure Enclave. They are never uploaded to any OpenTrawl or Agent Keyring server. Your Macs and iPhones keep each other up to date through your own iCloud private database, which we have no access to; every password there is encrypted to the receiving device's Secure Enclave key first. An approval may also carry that computer's own copies of its Automatic passwords, each encrypted so only that computer can open it.

## Zero-data-retention encrypted relay

When you pair a computer, answer an approval request, send a Stop signal or deliver a rule update, the message travels through our zero-data-retention relay at `push.opentrawl.sh` (AWS `eu-west-1`, Ireland), or your own self-hosted `agent-keyring-box`:

- **Zero per-request logs:** the relay Lambda has zero `console.*` calls, its IAM role has no CloudWatch Logs permissions, and the `/aws/lambda/opentrawl-push-relay` CloudWatch log group is destroyed.
- **No box IDs or tokens in URLs:** fixed endpoints (`/v1/box`, `/v1/push`) take random box IDs and access tokens only in headers (`x-akr-box`, `x-akr-token`), and only hashes of access tokens are kept while a box lives.
- **End-to-end encrypted boxes:** every box is AES-256-GCM encrypted between your devices and the requesting computer. The relay sees only random box IDs and ciphertext and can drop or delay a message, never read or forge one.
- **Deletion and expiry:** a join, answer or update box is deleted as soon as it is picked up. Unread boxes stop being served the moment their time runs out (10 minutes for a join or answer, 45 minutes for an approval grant that Stop marks, 7 days for a computer's update mailbox), and AWS then removes expired rows from DynamoDB automatically, usually within a few days.

## Blind push notification relay

When an agent on another computer asks your iPhone or Apple Watch to approve a sign-in, it sends an end-to-end encrypted push payload through our stateless push relay at `push.opentrawl.sh` (hosted on AWS in `eu-west-1`, Ireland). The relay signs the request with our Apple Developer push key and forwards the opaque payload straight to Apple's push servers.

The relay cannot read the website, account name or reason inside the payload. It stores no raw device tokens, no IP addresses and no message contents. To prevent abuse and count daily push volume, it keeps only short-lived SHA-256 hashes of device tokens (1 hour for rate limiting, 35 days for daily counts). If you build the apps with your own Apple Developer account, you can run your own relay or push straight to Apple instead.

## Anonymous update check

Once a day, Agent Keyring checks `https://push.opentrawl.sh/v1/version` to see if a newer release is available and to count active users. That check sends one stable, anonymous, non-reversible SHA-256 hash (derived from your app-scoped iCloud user identifier when signed in so your Mac and iPhone count as one user, or a random local identifier otherwise), the app version, the operating system (`macos`, `ios`, `watchos` or `linux`) and CPU architecture. It never sends passwords, website names, account names, Apple IDs or personal details, and the server does not store IP addresses. Daily and monthly counts expire automatically after 90 days.

You can turn the update check off at any time in **Devices** (Mac) or **Settings** (iPhone), via the `no_telemetry` preference, or by setting `AGENT_KEYRING_NO_TELEMETRY=1`.

## Beta waitlist emails

If you submit your email address and device checkboxes on `keyring.opentrawl.sh`, we store them in AWS (`eu-west-1`) solely to send you Agent Keyring beta and TestFlight invites. We do not sell, rent or share your email address with anyone.

## Contact

To delete your waitlist email or ask about privacy, email josh@jjpcodes.com or message @jjpcodes (https://x.com/jjpcodes).
