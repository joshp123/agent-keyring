---
name: agent-keyring
description: "Sign in to websites and use passwords and one-time codes from the user's Apple Passwords without the values passing through your conversation. Use whenever a task needs a login, a password or a two-factor code. Never ask the user to type or paste a password."
metadata:
  written_by: "AI on 2026-10-31 by model Claude Opus 5.5; browser workflow updated on 2026-11-01 by model gpt-6.1-sol"
---

# Agent Keyring

Agent Keyring holds the user's saved logins. You lease one login for the task you are doing, use it as often as the task needs, and release it when you are done. The user's rule for that login decides whether the lease is approved automatically, needs their Touch ID or iPhone approval, or is refused. One approval covers your whole task, including retries and two-factor steps, for up to 30 minutes. That is how long Agent Keyring will hand out the login for the task; it does not sign you out of the website, and anything already delivered stays where it went.

The values go into the sign-in form or the program, not into your output. Keep it that way: your conversation is stored, and the user is trusting the tool with their accounts.

If your harness has its own secret prompt, such as T3 Code's `request_secret`, don't use it for a login the user has saved. It asks them to type the password, which is what this tool exists to avoid.

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

**A browser with the Agent Keyring extension.** Use the browser and profile already provided for the task; Agent Keyring does not launch or restart them. `agent-keyring tabs` lists connected tabs with their URLs and titles. Choose your own task's tab, keep its complete opaque target, and use `agent-keyring fields --tab "$tab"` for its visible inputs and buttons, selectors and frame targets, never values. Then pass the exact fields and sign-in button:

```sh
agent-keyring fill "$lease" --tab "$tab" \
  --username '#username' --password '#password' --submit 'button[type=submit]'
```

Agent Keyring checks the document and frame are still the ones you selected and the frame is the saved site, fills, submits and clears what it typed. Run `tabs` again after navigation, then inspect the new page. A two-factor step is another `fill` under the same lease, for example `--code '#otp' --submit '#verify'`. For fields inside a frame, use the target printed beside those fields. Without `--tab`, filling works only when exactly one connected tab matches the saved site.

Repeating the same fill returns its recorded result without submitting again. If the site showed an error without leaving the page, inspect it before deliberately repeating with `--again`. A result of "uncertain" means the step may already have happened: look before doing anything else. After a browser restart, run `tabs` for new targets and keep the same lease.

**A browser without the extension.** Agent Keyring cannot fill it. Codex's in-app browser and T3's preview do not accept this extension. Use a connected browser for the sign-in; don't substitute `read`, clipboard input or a password in your browser tool's arguments. Safari support is a separate build slice.

**A program that needs the value.** Name the program when you lease, and Agent Keyring gives it the value on stdin. You get its exit status, not its output:

```sh
lease=$(agent-keyring lease LOGIN_ID --task "$task" --for program \
  --reason "..." -- /absolute/path/to/client login --password-stdin)
agent-keyring exec "$lease" --field password
```

**Two-factor codes.** Authenticator codes saved with the login come from Agent Keyring (`--code` when filling, `--field one-time-code` otherwise). Codes sent by SMS or email come from your own tools for the user's messages or mail, if you have them. Get them yourself rather than asking the user.

## On another machine

The standalone `agent-keyring` package includes this skill and needs no Mac app. On another machine on the user's tailnet, such as a Mac mini, server or cloud VM, enrol it once:

```sh
agent-keyring enrol --name "build server" --relay RELAY_HOST:17443
```

Ask the user for the relay address if you don't know it. `enrol` prints a code of eight groups and waits. Show the user that code and ask them to compare every group with the one Agent Keyring shows on their Mac before they approve there: the comparison is what proves this machine reached their own Agent Keyring, so it needs their eyes. After that, every command above works the same. Answers can take longer, because the user may approve on their iPhone.

Enrolment records the relay as this machine's authority, even if the Mac app is installed. Commands keep using that relay when it is unavailable; they do not switch to a local copy. On a Mac using its own imported logins, the client records the local app instead.

## When it doesn't work

- **Denied.** The user said no, and any reply they wrote is printed. Do what it says, or stop and ask them.
- **Unanswered.** Nobody answered in time. Tell the user, and try again when they are back, not in a loop.
- **Expired or released.** Lease again for the same task. Automatic logins don't ask; others ask once.
- **The page isn't the saved site.** You are not where the login belongs. Don't work around it.
- **Fields not found or ambiguous.** Inspect the page again and pass better selectors. This never asks the user again.
- **Clearing failed.** A value may still be on the page. Don't read the fields back; close the tab with your browser tools.
- **The site rejects the password.** The user's saved password is probably out of date. Tell them, and don't retry it.

`agent-keyring --help` describes every command, option and exit code.
