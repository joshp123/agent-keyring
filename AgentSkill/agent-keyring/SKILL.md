---
name: agent-keyring
description: "Sign in to websites and use passwords and one-time codes from the user's Apple Passwords without the values passing through your conversation, and set Agent Keyring up on the user's Mac and their other computers. Use whenever a task needs a login, a password or a two-factor code, and when the user asks you to set up Agent Keyring. Never ask the user to type or paste a password."
metadata:
  written_by: "AI on 2026-10-31 by model Claude Opus 5.5; setup updated on 2026-11-15 by model gpt-6.1-terra; one kind of lease on 2026-11-18 by model claude opus 5.5; setting up from one line on 2026-11-19 by model claude opus 5.5"
---

# Agent Keyring

Agent Keyring holds the user's saved logins. You lease one login for the task you are doing, use it as often as the task needs, and release it when you are done. The user's rule for that login decides whether the lease is approved automatically, needs their Touch ID or iPhone approval, or is refused. One approval covers your whole task, filling and reading alike, including retries and two-factor steps, for up to 30 minutes. That is how long Agent Keyring will hand out the login for the task; it does not sign you out of the website, and anything already delivered stays where it went.

The values go into the sign-in form or the program, not into your output. Keep it that way: your conversation is stored, and the user is trusting the tool with their accounts.

If your harness has its own secret prompt, such as T3 Code's `request_secret`, don't use it for a login the user has saved. It asks them to type the password, which is what this tool exists to avoid.

If the user asked you to set up Agent Keyring, read "Setting up" below first.

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

**Anywhere the extension cannot fill.** Codex's in-app browser and T3's preview do not accept this extension, and some pages defeat it. Use a connected browser if there is one. Otherwise read the value with the same lease, straight into the code that uses it, never into your output.

**A program that needs the value.** Pipe it in. `read` refuses to print to a terminal; nothing reaches your conversation unless the program prints it:

```sh
agent-keyring read "$lease" --field password | gh auth login --with-token
```

**Two-factor codes.** Authenticator codes saved with the login come from Agent Keyring (`--code` when filling, `--field one-time-code` otherwise). Codes sent by SMS or email come from your own tools for the user's messages or mail, if you have them. Get them yourself rather than asking the user.

## Setting up

The user has installed the Agent Keyring app on their Mac and copied their passwords into it, then asked you to set it up. Your job is to get agents on every computer they choose able to ask for passwords, with as little of their attention as possible: you do the work, and you ask them only what you cannot find out, in one message.

How it fits together: the Mac holds the passwords and shows each request. Other computers, and the iPhone and Apple Watch, reach the Mac through a relay, a small service on one computer of theirs that stays on, such as a Mac mini or a home server. That computer joins first; each other computer then joins with a one-time link from the Mac. Every join is one request the user approves on the Mac.

When you talk to the user, say "password", not "login"; "computer", not "machine"; and "Apple Watch" in full.

**1. Give this Mac's agents the command and this skill.** Do this every time; it is safe to repeat. On a new Mac nothing is on the path yet, so use the app's own command by its full path:

```sh
"/Applications/Agent Keyring.app/Contents/Helpers/agent-keyring" install
```

This links `agent-keyring` into `~/.local/bin`, links this skill for Codex and Claude Code, and registers the browser extension's helper. If `command -v agent-keyring` still finds nothing, `~/.local/bin` is not on your path: in the steps below, use the full path wherever they say `agent-keyring` on this Mac. If `install` stops at a folder that is read-only because something else manages it, such as a Nix or Home Manager configuration, it has not registered the browser helper either: tell the user what it said at the end, and carry on; don't change their configuration.

**2. See what is already done.** `agent-keyring relay-status` prints one of:

- `not-started`: carry on with step 3.
- `waiting`: a setup was started earlier and the computer that stays on never joined. Its link has expired; carry on with step 3, and step 5 starts it again.
- `connected`: this Mac already reaches the relay, so the computer that stays on has joined. Skip its question in step 4, and after asking go to step 6.

**3. Find out what you can before asking.** `agent-keyring machines` lists the computers on their Tailscale network, with this Mac first. For each other computer that is online, check over SSH whether it has the command and whether it runs the relay:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=5 HOST '$SHELL -lc "command -v agent-keyring"'
ssh -o BatchMode=yes -o ConnectTimeout=5 HOST "ps -axo command | grep '[a]gent-keyring-relay'"   # its address follows --listen
```

For HOST, use the user's own name for the computer if their `~/.ssh/config` has one, and otherwise the address `machines` printed. `BatchMode` makes a password prompt fail instead of waiting; if `ssh` exits with status 255, it could not connect, and the problem is SSH, not the command. The first check runs a login shell, because a plain SSH command can have a shorter path: in the `enrol` commands below, use the full path it printed in place of `agent-keyring`. The relay's `--listen` address is always that computer's Tailscale IP and a port.

What you need, and cannot provide yourself: SSH to each computer without a password; the `agent-keyring` command already installed on each one; and on the computer that stays on, the relay already running as a service. Agent Keyring cannot install itself on another computer yet. Today the only route is a Nix configuration with the `agent-keyring` and `agent-keyring-relay` packages from Agent Keyring's repository (github.com/joshp123/agent-keyring); the relay runs as a service with `--listen` set to the computer's Tailscale IP and a port. Apart from running `enrol` there, don't install, copy or start anything on another computer yourself. Where something is missing, the user has to add it.

**4. Ask the user, once.** In one message, using what you found, ask only what their request has not already told you:

- Which other computers run your agents?
- Do you want to approve from your iPhone and Apple Watch?
- "Requests reach your iPhone and Apple Watch through a computer of yours that stays on. Which one should that be?" Suggest the one already running the relay.

Say what you will call each computer, as the user would name it ("Mac mini", "Linux server"), not its network name. Name the computers that cannot join yet, and what each lacks, so they don't pick one expecting it to work. If more than one relay runs on a computer, an older version is probably still running beside the current one: show the user both command lines and ask which is current, in the same message.

If they want neither other computers nor the iPhone, this Mac is set up after step 1: tell them so and stop. If the computer that stays on lacks the command or the relay, nothing beyond this Mac can be set up yet: tell them what it needs and stop. Otherwise set up the computer that stays on even if none of the other computers they want can join yet: the iPhone and later computers need it.

**5. Connect this Mac to the relay, and add the computer that stays on.** That computer joins even if no agents run on it, and the relay works once it has. Give `--relay` the address after `--listen`, and use the computer's name in both `--reason` and `--name`:

```sh
link=$(agent-keyring setup-relay --relay IP:PORT --reason "You asked me to set up Agent Keyring on Mac mini.")
ssh HOST "agent-keyring enrol --name 'Mac mini' --invite '$link'"
```

`setup-relay` prints the link straight away. The link works for one computer, for ten minutes. `enrol` then waits, for up to ten minutes more, until the user approves on the Mac. Keep it running, in the background if your tool allows, and tell the user that a request to add that computer is waiting on their Mac. When `enrol` prints `Joined`, run `agent-keyring relay-status` every few seconds until it prints `connected`. If `enrol` ends without `Joined`, the request was denied or nobody answered: tell the user, and make a new link only if they want to try again.

**6. Add each other computer.** The same, with a new link for each:

```sh
link=$(agent-keyring invite)
ssh HOST "agent-keyring enrol --name 'Linux server' --invite '$link'"
```

You can run several at once; the Mac shows the requests one after another. Agents on each computer that joined find these instructions with `agent-keyring skill` there, and use Agent Keyring the same way as on the Mac. Answers can take longer, because the user may approve on their iPhone.

**7. The iPhone and Apple Watch,** if they want them. Tell the user to open Agent Keyring on their iPhone: it finds its invitation through iCloud Keychain, and a request to add it appears on the Mac. Then to open Agent Keyring on their Apple Watch, after the iPhone: the request to add it appears on the iPhone. You cannot install the apps or see whether these joined.

**8. Finish with one message:** which computers are set up, what the user still has to do on the iPhone and Apple Watch, and for each computer left out, what it needs.

## When it doesn't work

- **Denied.** The user said no, and any reply they wrote is printed. Do what it says, or stop and ask them.
- **Unanswered.** Nobody answered in time. Tell the user, and try again when they are back, not in a loop.
- **Expired or released.** Lease again for the same task. Automatic logins don't ask; others ask once.
- **The page isn't the saved site.** You are not where the login belongs. Don't work around it.
- **Fields not found or ambiguous.** Inspect the page again and pass better selectors. This never asks the user again.
- **Clearing failed.** A value may still be on the page. Don't read the fields back; close the tab with your browser tools.
- **The site rejects the password.** The user's saved password is probably out of date. Tell them, and don't retry it.

`agent-keyring --help` describes every command, option and exit code.
