# Agent Keyring security

Published: 2026-11-21
Updated: 2026-11-22
Made by: Josh Palmer (https://x.com/jjpcodes)
HTML page: https://agent-keyring.jjpcodes.com/security/
Threat model in the source: https://github.com/opentrawl/agent-keyring/blob/main/docs/threat-model.md
Home: /index.md
Comparison: /compare.md

There's no cloud vault and no account. Your passwords stay encrypted on your own devices, and an agent gets one only when you approve it, or when you've set that password to Automatic.

## Where your passwords are

Your Mac and iPhone encrypt their approval copies with keys in their Secure Enclave, the chip behind Touch ID and Face ID. Those keys can't leave the chip. Your Apple Watch keeps no passwords at all: each request arrives with the one password it needs, encrypted so only your Apple Watch can open it.

## What your agent sees

You approve once, and your agent's skill picks the cleanest route for whatever it's driving. In Chrome, Brave, Edge, Arc or Chromium with the extension loaded, the agent names the form fields and the extension checks the website, types the password, submits and clears the fields so nothing enters chat or logs.

Anywhere the extension doesn't run (built-in agent browsers, Safari, desktop apps via computer use, or command-line tools such as `gh`), the agent passes the approved password straight into the code, app or tool through `agent-keyring read`, which refuses to print to a terminal.

## How a request reaches you

Agents on your Mac ask the Mac app directly. An agent on another computer reaches your iPhone and Apple Watch with an Apple push notification, and your Mac too if it's awake. Your answer goes straight back to that computer over Tailscale (https://tailscale.com/), with the password encrypted for that one computer. There's no Agent Keyring server in between. Apple can see notification details, including the request ID and the fallback text "A request is waiting." Your device decrypts the website, account and reason.

## What you're shown

Every request shows the website, the account and the computer that asked. Agent Keyring fills those in itself, so an agent can't fake them. The agent's name and its reason are the agent's own words, which is why the reason sits in quotation marks. An agent tricked by a web page can write anything there.

Changing a rule or adding a device requires your approval, so an agent can't switch a password to Automatic or add a computer of its own.

## What an approval covers

One password, for one task, for 30 minutes at most. Retries and the two-factor step are included. Access ends when the agent releases it, when the computer receives your Stop, or after 30 minutes. For an Ask password, the agent's computer gets time-limited codes for those 30 minutes, and the setup key stays on your devices.

If you deny a request, that computer waits a minute before it can ask for the same password again. Deny it twice in a row and it waits five minutes, then fifteen.

## Automatic passwords

A computer you choose keeps its own encrypted copy of each Automatic password, two-factor setup key included, so agents there can sign in while you sleep. Only use Automatic for a password you'd leave on that computer anyway. Switch it back to Ask and a computer deletes its copy when it receives the updated list from your Mac.

## What each device keeps

| Device | What it keeps | What it can open |
| --- | --- | --- |
| Your Mac | An encrypted copy of every password you copied from Apple Passwords | One password per approval, after Touch ID |
| Your iPhone | Its own encrypted copy of your passwords | One password per approval, after Face ID |
| Your Apple Watch | No passwords | The one password that arrives with a request, when you tap Approve |
| A computer your agents run on | The website and account name of each password, its own encrypted copy of each Automatic password, and copies for your Apple Watch that it can't open | Its Automatic passwords, and an Ask password once you approve it |

## What it can't do

- Watch what an agent does once it's signed in. Ending an approval doesn't sign the agent out of the website either.
- Take a password back. Stop and the 30-minute limit end what Agent Keyring hands out. They don't erase what a computer already received.
- Stop an agent that goes looking for the password. While the extension fills a form (its normal wait is up to 20 seconds before clearing the fields), an agent that controls that browser can read the password there. An agent can also pipe a password into a program it wrote itself.
- Protect an unlocked Mac. Someone sitting at it can ask for passwords like any agent there. They still need your approval for an Ask password, but not for an Automatic one.
- Wipe a lost iPhone. Remove it in Devices and it gets no more requests, but its copy of your passwords stays on the phone behind Face ID. If someone may get past that, change those passwords.
- Keep passwords out of the agent outside the browser extension. In built-in browsers, Safari, computer use or CLI tools, the agent handles the password itself via `agent-keyring read`.
- Use passkeys or codes sent by SMS or email.
- Sync with Apple Passwords. Apple only hands passwords over when you start an export, so export again after you change one.
