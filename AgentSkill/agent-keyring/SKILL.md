---
name: agent-keyring
description: "Sign in to websites and use passwords and one-time codes from the user's Apple Passwords without the values passing through your conversation. Use whenever a task needs a login, a password or a two-factor code. Never ask the user to type or paste a password."
metadata:
  written_by: "AI on 2026-10-31 by model Claude Opus 5.5; setup updated on 2026-11-15 by model gpt-6.1-terra"
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

**A browser with the Agent Keyring extension.** Use the browser and profile already provided for the task; Agent Keyring does not launch or restart them. `agent-keyring tabs` lists connected tabs with their URLs and titles. Choose your own task's tab, keep its complete opaque target, and use `agent-keyring fields --tab "$tab"` for its visible inputs and buttons, selectors and frame targets, never values. Copy selectors exactly, including ` >>> ` boundaries for controls inside open shadow roots. Then pass the exact fields and sign-in button:

```sh
agent-keyring fill "$lease" --tab "$tab" \
  --username '#username' --password '#password' --submit 'button[type=submit]'
```

Agent Keyring checks the document and frame are still the ones you selected and the frame is the saved site, fills, submits and clears what it typed. Run `tabs` again after navigation, then inspect the new page. A two-factor step is another `fill` under the same lease, for example `--code '#otp' --submit '#verify'`. For fields inside a frame, use the target printed beside those fields. Without `--tab`, filling works only when exactly one connected tab matches the saved site.

Repeating the same fill returns its recorded result without submitting again. If the site showed an error without leaving the page, inspect it before deliberately repeating with `--again`. Filling waits up to ten seconds for the submit control to become enabled, then up to ten more seconds after clicking for browser confirmation (at most twenty seconds of retention); without browser confirmation, values are cleared and the result is "uncertain", with observations such as an address change or removed fields. A browser fill exits with status **0** for Submitted, **3** for Uncertain (including a replay), **1** for refused or unavailable, and **2** for incorrect usage. Status 3 means inspect the page, not that the site rejected the login. A recorded Uncertain reply says the earlier fill finished without browser confirmation; an interrupted pending receipt says it may have started. Neither replay fills or submits again. Those observations do not establish success: inspect the page and decide what to do next; repeating the recorded step will not submit it again. After a browser restart, run `tabs` for new targets and keep the same lease.

**A browser without the extension.** Agent Keyring cannot fill it. Codex's in-app browser and T3's preview do not accept this extension. Use a connected browser for the sign-in; don't substitute `read`, clipboard input or a password in your browser tool's arguments. Safari support is a separate build slice.

**A program that needs the value.** Name the program when you lease, and Agent Keyring gives it the value on stdin. You get its exit status, not its output:

```sh
lease=$(agent-keyring lease LOGIN_ID --task "$task" --for program \
  --reason "..." -- /absolute/path/to/client login --password-stdin)
agent-keyring exec "$lease" --field password
```

**Two-factor codes.** Authenticator codes saved with the login come from Agent Keyring (`--code` when filling, `--field one-time-code` otherwise). Codes sent by SMS or email come from your own tools for the user's messages or mail, if you have them. Get them yourself rather than asking the user.

## On another machine

The setup agent does the verification. The user only approves on their Mac. Use authenticated SSH to the actual machines, independently of the relay connection. Never take a code from the relay's network response or from the approving Mac and pass it back as if it came from the other machine. Stop on any mismatch; do not try to work around it.

To connect the Mac to a new relay, run its bundled command on the Mac:

```sh
agent-keyring setup-relay --relay RELAY_HOST:PORT
# On the relay host over SSH, read the current relay process log entry
# "compare pairing fingerprint on approver". Use the entire fingerprint:
agent-keyring verify-relay --code 'XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX'
```

Read the log from the relay process on the expected SSH host; do not use an old entry. The Mac now offers the user one approval. Wait for it to complete before enrolling machines.

To add another machine on the user's tailnet, run its standalone command on that machine over SSH and leave it waiting:

```sh
agent-keyring enrol --name "build server" --relay RELAY_HOST:17443
```

Read the `AGENT_KEYRING_ENROL_CODE=` line from that SSH session. On the approving Mac, use the same machine name and the complete code:

```sh
agent-keyring verify-machine --name "build server" --code 'XXXX XXXX XXXX XXXX XXXX XXXX XXXX XXXX'
```

The Mac offers the user one approval. Wait for the enrol command to finish. If the approver keys change, the command prints a new code: verify that new code from the SSH session. If the Mac has not received the enrolment yet, retry verification of the same code. Find the relay address and process log yourself. After enrolment, the commands above work the same. Answers can take longer, because the user may approve on their iPhone.

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
