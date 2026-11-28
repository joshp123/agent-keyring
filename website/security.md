# Agent Keyring security

Published: 2026-11-21
Updated: 2026-11-24
Made by: Josh Palmer (https://x.com/jjpcodes)
HTML page: https://keyring.opentrawl.sh/security/
Threat model in the source: https://github.com/opentrawl/agent-keyring/blob/main/docs/threat-model.md
Home: /index.md
Comparison: /compare.md
Privacy: /privacy.md

There's no account and no vault of ours. Your passwords stay encrypted on your own devices, our relay runs with zero data retention, and an agent gets a password only when you approve it or when you've set that password to Automatic.

## Where your passwords are

Your Mac, iPhone and Apple Watch each keep their own encrypted copies of your passwords, with keys in their Secure Enclave, the chip behind Touch ID and Face ID. Those keys can't leave the chip. Your iPhone sends your Apple Watch its copies directly. Copies your Mac encrypts for your Apple Watch pass through your own iCloud on the way, as ciphertext only your Apple Watch can open. No computer and no relay ever carries them.

A Mac without Touch ID, such as a Mac mini or Mac Studio, keeps your passwords only if you opt in to approving with its Mac password. Its keys are still in its Secure Enclave, and no agent can open an Ask password without macOS asking for that password. A typed password is weaker than Touch ID or Face ID: an agent or tool that knows your Mac login password, for example from a `sudo` prompt, could approve its own requests. If you add a Touch ID keyboard or an Apple Watch later, macOS accepts those too, and the password still works. A computer that only runs agents should have only the `agent-keyring` command, never the app.

Your Mac and iPhone find each other through your own iCloud Keychain, which Apple encrypts end to end.

## Keeping your devices in step

Every Mac and iPhone is an equal: none is in charge, and you can copy from Apple Passwords on any of them. They keep each other up to date through your own iCloud private database. Each password is encrypted to the receiving device's Secure Enclave key before it leaves the device you copied it on, so iCloud only ever holds ciphertext: we can't read your passwords, Apple can't, and your internet provider can't. The list of devices and the list of passwords and rules are signed by one of your devices, and every device checks those signatures, so nobody who can write to your iCloud can add a device or change a rule.

The list of websites and account names is kept in CloudKit's encrypted fields. With Advanced Data Protection on, only your devices can read it; without it, Apple holds the keys, as it does for the rest of your iCloud data. Each device's list of passwords is signed with that device's key too, and a rule only ever comes from a list you approved with Touch ID or Face ID.

If two devices change the same password's rule at once, the later change wins on every device. Blocking a password deletes it from every device.

## What your agent sees

You approve once, and your agent's skill picks the cleanest route for whatever it's driving. In Chrome, Brave, Edge, Arc or Chromium with the extension loaded, the agent names the form fields and the extension checks the website, types the password, submits and clears the fields so nothing enters chat or logs.

Anywhere the extension doesn't run (built-in agent browsers, Safari, desktop apps via computer use, or command-line tools such as `gh`), the agent passes the approved password straight into the code, app or tool through `agent-keyring read`, which refuses to print to a terminal.

## How push notifications work

Agents on your Mac ask the Mac app directly, with no network hop at all. When an agent on another computer needs your iPhone, Apple Watch or Mac, it encrypts the request (website, account and reason) for your devices and sends that opaque payload through our stateless blind push relay at `push.opentrawl.sh` (AWS `eu-west-1`). The relay signs the request with our Apple Developer push key and forwards it to Apple's push servers, without storing raw device tokens, IP addresses or message contents. Apple sees only standard notification metadata and the fallback text "A request is waiting."

Your approval answer is encrypted for the one computer that asked and waits for it in an ephemeral box at `push.opentrawl.sh`. Computers join the same way, with a one-time code that also encrypts their join request so the relay can't read or change it. Stop on any of your devices marks the approval stopped at the relay, and the computer checks there before every use, so an approval it can't check isn't used. macOS doesn't open a quit app for a push, so turn on Open Agent Keyring at Login if you want your Mac to answer agents on other computers.

## Zero data retention on our relay

The relay at `push.opentrawl.sh` (AWS `eu-west-1`) is built for zero data retention:

- **Zero per-request logs:** the relay Lambda has zero `console.*` calls, its IAM role has no CloudWatch Logs permissions, and the `/aws/lambda/opentrawl-push-relay` CloudWatch log group is destroyed.
- **No box IDs or tokens in URLs:** clients talk to fixed endpoints (`/v1/box`, `/v1/push`) with random box IDs and access tokens sent only in headers (`x-akr-box`, `x-akr-token`), and only hashes of access tokens are kept while a box lives.
- **End-to-end encrypted boxes:** every box is AES-256-GCM encrypted between your devices and the requesting computer. The relay sees only random box IDs and ciphertext: it can drop or delay a message, never read or forge one.
- **Deletion and expiry:** a join, answer or update box is deleted as soon as it is picked up. Unread boxes stop being served the moment their time runs out (10 minutes for a join or answer, 45 minutes for an approval grant that Stop marks, 7 days for a computer's update mailbox), and AWS then removes expired rows from DynamoDB automatically, usually within a few days.

You can self-host the relay with `agent-keyring-box` behind HTTPS with a certificate your iPhone and Apple Watch trust, such as one from Let's Encrypt. If you build the apps with your own Apple Developer account, you can run your own push relay or push straight to Apple instead.

## Anonymous update check

Once a day, Agent Keyring checks `https://push.opentrawl.sh/v1/version` with one stable, anonymous, non-reversible SHA-256 hash (derived from your app-scoped iCloud user ID when signed in, or a random local ID otherwise), app version, OS and CPU architecture so it can notify you of new releases and let us count active users. No IP addresses, Apple IDs, websites, accounts or passwords are sent or stored. Those daily and monthly counts expire after 90 days. Push counts are kept apart from them: to limit abuse and count daily pushes, the relay keeps SHA-256 hashes of device tokens, for 1 hour and 35 days. You can turn it off in Devices (Mac), Settings (iPhone), via `no_telemetry`, or with `AGENT_KEYRING_NO_TELEMETRY=1`. See the privacy policy at /privacy.md (https://keyring.opentrawl.sh/privacy/) for full details.

## What you're shown

Every request shows the website, the account and the computer that asked. Agent Keyring fills those in itself, so an agent can't fake them. The agent's name and its reason are the agent's own words, which is why the reason sits in quotation marks. An agent tricked by a web page can write anything there.

Changing a rule or adding a device requires your approval, so an agent can't switch a password to Automatic or add a computer of its own.

## What an approval covers

One password, for one task, for 30 minutes at most. Retries and the two-factor step are included. Access ends when the agent releases it, when the computer receives your Stop, or after 30 minutes. For an Ask password, the agent's computer gets time-limited codes for those 30 minutes, and the setup key stays on your devices.

If you deny a request, that computer waits a minute before it can ask for the same password again. Deny it twice in a row and it waits five minutes, then fifteen.

## Automatic passwords

A computer you choose keeps its own encrypted copy of each Automatic password, two-factor setup key included, so agents there can sign in while you sleep. Only use Automatic for a password you'd leave on that computer anyway. Switch it back to Ask and a computer deletes its copy when it receives the updated list from your Mac or iPhone. It receives that list from its update mailbox, which your Mac and iPhone write after every change and once a day, or with the next answer to one of its requests. A computer that hasn't heard from your devices for a week stops using its Automatic passwords on its own.

## What each device keeps

| Device | What it keeps | What it can open |
| --- | --- | --- |
| Your Mac | An encrypted copy of every password you copied from Apple Passwords | One password per approval, after Touch ID (or your Mac password, on a Mac without Touch ID that you opted in) |
| Your iPhone | Its own encrypted copy of your passwords | One password per approval, after Face ID |
| Your iCloud private database | The signed lists, each device's list of passwords without the passwords, and copies encrypted to each device | Nothing: every copy opens only on the device it was encrypted for |
| Your Apple Watch | Its own encrypted copy of every password that isn't Blocked | One password per approval, when you tap Approve on your wrist |
| A computer your agents run on | The website and account name of each password, and its own encrypted copy of each Automatic password | Its Automatic passwords, and an Ask password once you approve it |
| Our zero-data-retention relay (`push.opentrawl.sh`) | Zero per-request logs. Only AES-256-GCM ciphertext boxes under random IDs and hashed access tokens until picked up or expired | Nothing: it can drop or delay a message, never read or forge one |

## What it can't do

- Watch what an agent does once it's signed in. Ending an approval doesn't sign the agent out of the website either.
- Take a password back. Stop and the 30-minute limit end what Agent Keyring hands out. They don't erase what a computer already received.
- Stop an agent that goes looking for the password. While the extension fills a form (its normal wait is up to 20 seconds before clearing the fields), an agent that controls that browser can read the password there. An agent can also pipe a password into a program it wrote itself.
- Protect an unlocked Mac. Someone sitting at it can ask for passwords like any agent there. They still need your approval for an Ask password, but not for an Automatic one.
- Wipe a lost iPhone. Remove it in Devices and it gets no more requests, but its copy of your passwords stays on the phone behind Face ID. If someone may get past that, change those passwords.
- Keep passwords out of the agent outside the browser extension. In built-in browsers, Safari, computer use or CLI tools, the agent handles the password itself via `agent-keyring read`.
- Use passkeys or codes sent by SMS or email.
- Sync with Apple Passwords. Apple only hands passwords over when you start an export, so export again after you change one, on your Mac or iPhone. A reminder, off by default, can tell you once your copy is a week old.
- Hide which websites you have from Apple without Advanced Data Protection. Your passwords stay sealed either way.
