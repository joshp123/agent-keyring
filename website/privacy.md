# Agent Keyring privacy policy

Updated: 2026-11-23
Website: https://keyring.opentrawl.sh/privacy/
Source code: https://github.com/opentrawl/agent-keyring

Agent Keyring keeps your passwords on your own devices. There is no cloud vault, no account, and no ad or tracking SDK.

## Passwords and approvals

Your passwords stay encrypted on your own Mac and iPhone, protected by keys kept in each device's Secure Enclave. They are never uploaded to any OpenTrawl or Agent Keyring server. When you approve a request from your iPhone or Apple Watch, the encrypted answer goes straight back to the asking computer over your Tailscale network.

## Blind push notification relay

When an agent on another computer asks your iPhone or Apple Watch to approve a sign-in, it sends an end-to-end encrypted push payload through our stateless push relay at `push.opentrawl.sh` (hosted on AWS in `eu-west-1`, Ireland). The relay signs the request with our Apple Developer push key and forwards the opaque payload straight to Apple's push servers.

The relay cannot read the website, account name, reason or Watch password inside the payload. It stores no raw device tokens, no IP addresses and no message contents. To prevent abuse and count daily push volume, it keeps only short-lived SHA-256 hashes of device tokens (1 hour for rate limiting, 35 days for daily counts). If you build the apps with your own Apple Developer account, you can run your own relay or push straight to Apple instead.

## Anonymous update check

Once a day, Agent Keyring checks `https://push.opentrawl.sh/v1/version` to see if a newer release is available and to count active installs. That check sends a random per-install identifier, the app version, the operating system (`macos`, `ios`, `watchos` or `linux`) and CPU architecture. It never sends passwords, website names, account names or personal details, and the server does not store IP addresses. Daily and monthly install counts expire automatically after 90 days.

You can turn the update check off at any time in Agent Keyring Settings or by setting `AGENT_KEYRING_NO_TELEMETRY=1`.

## Beta waitlist emails

If you submit your email address and device checkboxes on `keyring.opentrawl.sh`, we store them in AWS (`eu-west-1`) solely to send you Agent Keyring beta and TestFlight invites. We do not sell, rent or share your email address with anyone.

## Contact

To delete your waitlist email or ask about privacy, email josh@jjpcodes.com or message @jjpcodes (https://x.com/jjpcodes).
