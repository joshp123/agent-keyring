---
name: agent-keyring
description: "Sign in to websites and use passwords and one-time codes from the user's Apple Passwords without the values passing through your conversation. Use whenever a task needs a login, a password or a two-factor code. Never ask the user to type or paste a password."
metadata:
  written_by: "AI on 2026-10-31 by model Claude Opus 5.5"
---

# Agent Keyring

Agent Keyring holds the user's saved logins. You lease one login for the task you are doing, use it as often as the task needs, and release it when you are done. The user's rule for that login decides whether the lease is approved automatically, needs their Touch ID or iPhone approval, or is refused. One approval covers your whole task, including retries and two-factor steps, for up to 30 minutes.

The values go into the sign-in form or the program, not into your output. Keep it that way: your conversation is stored, and the user is trusting the tool with their accounts.

## The shape of every sign-in

```sh
agent-keyring find example.com          # logins, accounts and login IDs; no secrets
lease=$(agent-keyring lease LOGIN_ID --task "$task" --reason "What the user asked for, in one line")
# ... use the lease, as many times as the task needs ...
agent-keyring release "$lease"
```

- **The task reference** names this job. Make one up when you start the job and keep it through every retry. A new job gets a new reference. Leases are per task, so a reused reference mixes jobs, and a fresh one for the same job asks the user again.
- **The reason** is shown to the user when they are asked. Say what they asked you to do, plainly. It is labelled as your claim, so don't oversell it.
- **`lease` waits** while the user is asked, for up to ten minutes, and prints only the lease ID. Keep it running and keep working on the task: the user's answer comes back to this command, not to your conversation, so if you stop or end your turn while it waits, the answer reaches nobody. Agent Keyring already shows the user what you asked for; you don't need to tell them. If your tool stops the command early, rejoin the same request with `agent-keyring status LEASE --wait`. Never start a new lease for the same task to retry; that one joins the waiting request anyway.

## Using the lease

**Google Chrome on this Mac, reached over its debugging endpoint.** Other Chromium browsers aren't supported yet and say so. Inspect the page with your own browser tools, then pass the exact fields and the sign-in button:

```sh
agent-keyring fill "$lease" --browser "$endpoint" --tab "$tab" \
  --username '#username' --password '#password' --submit 'button[type=submit]'
```

Agent Keyring checks the page is the saved site, fills, submits and clears what it typed. Then look at the new page yourself. A two-factor step is another `fill` under the same lease, for example `--code '#otp' --submit '#verify'`. If the site showed an error without leaving the page, inspect it before repeating the step with `--again`. A result of "uncertain" means the step may already have happened: look before doing anything else.

**A browser with no debugging endpoint, driven from your own code.** If your code can type into the page itself, lease with `--for agent-process`. Then have that same code run `agent-keyring read "$lease" --field password` and pass its output straight to the field, so the value goes from the command to the page without appearing in your output. Don't run `read` as a shell command of its own: shell tools show you what a command prints, and `read` refuses a terminal for the same reason.

```sh
lease=$(agent-keyring lease LOGIN_ID --task "$task" --for agent-process --reason "...")
```

The user's approval says plainly that the value goes to your code, so use this route only when the browser leaves you no other, and only through input your environment allows.

**A program that needs the value.** Name the program when you lease, and Agent Keyring gives it the value on stdin. You get its exit status, not its output:

```sh
lease=$(agent-keyring lease LOGIN_ID --task "$task" --for program \
  --reason "..." -- /absolute/path/to/client login --password-stdin)
agent-keyring exec "$lease" --field password
```

**Two-factor codes.** Authenticator codes saved with the login come from Agent Keyring (`--code` when filling, `--field one-time-code` otherwise). Codes sent by SMS or email come from your own tools for the user's messages or mail, if you have them. Get them yourself rather than asking the user.

## On a machine without the app

Agent Keyring runs on the user's Mac. On another machine on their tailnet, such as a server or a cloud VM, enrol it once:

```sh
agent-keyring enrol --name "build server" --relay mac-mini:17443
```

Ask the user for the relay address if you don't know it. `enrol` prints a code of eight groups and waits. Show the user that code and ask them to compare every group with the one Agent Keyring shows on their Mac before they approve there: the comparison is what proves this machine reached their own Agent Keyring, so it needs their eyes. After that, every command above works the same. Answers can take longer, because the user may approve on their iPhone.

## When it doesn't work

- **Denied.** The user said no, and any reply they wrote is printed. Do what it says, or stop and ask them.
- **Unanswered.** Nobody answered in time. Tell the user, and try again when they are back, not in a loop.
- **Expired or released.** Lease again for the same task. Automatic logins don't ask; others ask once.
- **The page isn't the saved site.** You are not where the login belongs. Don't work around it.
- **Fields not found or ambiguous.** Inspect the page again and pass better selectors. This never asks the user again.
- **Clearing failed.** A value may still be on the page. Don't read the fields back; close the tab with your browser tools.
- **The site rejects the password.** The user's saved password is probably out of date. Tell them, and don't retry it.

`agent-keyring --help` describes every command, option and exit code.
