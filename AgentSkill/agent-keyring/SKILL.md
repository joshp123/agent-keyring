---
name: agent-keyring
description: "Sign in to websites and use passwords and one-time codes from the user's Apple Passwords without the values passing through your conversation, and set Agent Keyring up on the user's Mac and their other computers. Use whenever a task needs a login, a password or a two-factor code, and when the user asks you to set up Agent Keyring. Never ask the user to type or paste a password."
metadata:
  written_by: "AI on 2026-10-31 by model Claude Opus 5.5; setup updated on 2026-11-15 by model gpt-6.1-terra; one kind of lease on 2026-11-18 by model claude opus 5.5; setting up from one line on 2026-11-19 by model claude opus 5.5; denials, undoing install and this Mac's own agents on 2026-11-19 by model claude opus 5.5; no more linking, --agent and short holds after a denial on 2026-11-20 by model claude opus 5.5; Focus and two-factor codes on 2026-11-20 by model claude opus 5.5; setting up with no relay, and complaints, on 2026-11-21 by model claude opus 5.5; ask-before-scanning cardinal rule and optional browser extension setup on 2026-11-23 by model gemini-4-neon"
---

# Agent Keyring

Agent Keyring holds the user's saved logins. You lease one login for the task you are doing, use it as often as the task needs, and release it when you are done. The user's rule for that login decides whether the lease is approved automatically, needs their Touch ID or iPhone approval, or is refused. One approval covers your whole task, filling and reading alike, including retries and two-factor steps, for up to 30 minutes. That is how long Agent Keyring will hand out the login for the task; it does not sign you out of the website, and anything already delivered stays where it went.

The values go into the sign-in form or the program, not into your output. Keep it that way: your conversation is stored, and the user is trusting the tool with their accounts.

If your harness has its own secret prompt, such as T3 Code's `request_secret`, don't use it for a login the user has saved. It asks them to type the password, which is what this tool exists to avoid.

If the user asked you to set up Agent Keyring, read "Setting up" below first.

## The shape of every sign-in

```sh
agent-keyring find example.com          # logins, accounts and login IDs; no secrets
lease=$(agent-keyring lease LOGIN_ID --task "$task" --reason "What the user asked for, in one line" --agent "YOUR NAME")
# ... use the lease, as many times as the task needs ...
agent-keyring release "$lease"
```

- **The task reference** names this job. Make one up when you start the job and keep it through every retry. A new job gets a new reference. Leases are per task, so a reused reference mixes jobs, and a fresh one for the same job asks the user again.
- **The agent** is your own name as the user knows it, such as "Claude Code", "Codex" or "pi": put your own in place of YOUR NAME. It is shown as who is asking; without it, a request made over SSH can only say "an agent".
- **The reason** is shown to the user when they are asked. Say what they asked you to do, plainly. It is labelled as your claim, so don't oversell it.
- **`lease` waits** while the user is asked, for up to ten minutes, and prints only the lease ID. Keep it running and keep working on the task: the user's answer comes back to this command, not to your conversation, so if you stop or end your turn while it waits, the answer reaches nobody. Agent Keyring already shows the user what you asked for; you don't need to tell them. If your tool stops the command early, rejoin the same request with `agent-keyring status LEASE --wait`. Never start a new lease for the same task to retry; that one joins the waiting request anyway.

**Trying it out.** When the user asks you to try Agent Keyring, or to show that it works, ask for the test password, never one of theirs: example.com, account you@example.com, password "hello". Agent Keyring always keeps it, on every computer the user has connected: `agent-keyring find example.com` gives its login ID. Give a reason that says what is happening, such as "To check that Agent Keyring works."

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

**Two-factor codes.** The secret that makes a login's codes stays on the user's devices. An approval gives you the codes for that approval's 30 minutes, never the secret, so you cannot make codes after it ends. (A login set to Automatic is the exception: the computer it is Automatic for holds its own sealed copy, secret included.) Authenticator codes saved with the login come from Agent Keyring (`--code` when filling, `--field one-time-code` otherwise). Codes sent by SMS or email come from your own tools for the user's messages or mail, if you have them. Get them yourself rather than asking the user.

## Setting up

The user has installed the Agent Keyring app on their Mac and copied their passwords into it, then asked you to set it up.

**Cardinal rule: propose first, act only after the user agrees.** Tell the user what you suggest doing and ask their permission before scanning their Tailscale network, probing computers over SSH, registering a browser helper, or changing any files or settings.

How it fits together: the Mac holds the passwords and the list of the user's devices and computers. Each other computer, and the iPhone and Apple Watch, joins the Mac once, with a request the user approves on the Mac. After that, an agent on another computer asks that computer's own `agent-keyring`, which sends the request straight to the iPhone and Apple Watch and takes the answer itself: the Mac does not need to be awake. Agents on this Mac ask the Mac directly. Everything travels over Tailscale, so every computer and device must be signed in to the user's Tailscale network.

When you talk to the user, say "password", not "login"; "computer", not "machine"; and "Apple Watch" in full.

**1. The command on this Mac.** Agent Keyring changes nothing in the user's folders or settings: it does not link itself onto the path. Run the app's own command by its full path:

```sh
"/Applications/Agent Keyring.app/Contents/Helpers/agent-keyring" skill
```

Wherever the steps below say `agent-keyring` on this Mac, use that full path, unless `command -v agent-keyring` already finds it. Never add it to their path, shell files or agent settings yourself; if they want that, they will do it or ask you. An earlier version's `install` may have changed some links; `install --undo` puts them back, and you run it only if the user asks.

**2. Propose what to set up and ask permission first.** Before running `agent-keyring machines`, probing SSH hosts, or configuring anything, tell the user what you suggest setting up and ask what they want to include (skipping anything they already told you):

- **Other computers:** Ask if they have other computers (such as a Mac mini or Linux server) that run agents, and ask permission before checking their Tailscale network (`agent-keyring machines`) and probing online computers over SSH to see which ones have `agent-keyring` installed.
- **iPhone and Apple Watch:** Ask if they want to approve requests from their iPhone and Apple Watch.
- **Optional browser extension (Chrome, Chromium, Brave, Edge):** Offer to set up the optional browser extension if they want agents to fill web forms directly in a Chrome-family browser profile without piping values through commands. (No extension is needed for Safari, built-in agent browsers, desktop apps or CLI tools.)

If they want only this Mac with no browser extension, this Mac is already ready after step 1: tell them so and stop.

**3. Check the computers they agreed to scan.** Only after the user says yes to checking their other computers, run `agent-keyring machines` to list the computers on their Tailscale network (with this Mac first), and for each online computer they want checked, test over SSH whether it has the command:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=5 HOST '$SHELL -lc "command -v agent-keyring"'
```

For HOST, use the user's own name for the computer if their `~/.ssh/config` has one, and otherwise the address `machines` printed. `BatchMode` makes a password prompt fail instead of waiting; if `ssh` exits with status 255, it could not connect, and the problem is SSH, not the command. The check runs a login shell, because a plain SSH command can have a shorter path: in the `enrol` commands below, use the full path it printed in place of `agent-keyring`.

What you need, and cannot provide yourself: SSH to each computer without a password, and the `agent-keyring` command already installed on each one. Agent Keyring cannot install itself on another computer yet. Today the only route is a Nix configuration with the `agent-keyring` package from Agent Keyring's repository (github.com/joshp123/agent-keyring). The iPhone and Apple Watch answer each request at that computer's Tailscale address, port 17446, so a firewall there must allow that port on Tailscale. Apart from running `enrol` there after the user approves, don't install, copy or start anything on another computer yourself. Where something is missing, tell the user what each computer lacks and confirm which ready computers to add (using plain names like "Mac mini" or "Linux server", not network hostnames).

**4. Add each approved computer,** with a new link for each:

```sh
link=$(agent-keyring invite)
ssh HOST "agent-keyring enrol --name 'Linux server' --invite '$link'"
```

The link works for one computer, for ten minutes. `enrol` then waits, for up to ten minutes more, until the user approves on the Mac. Keep it running, in the background if your tool allows, and tell the user that a request to add that computer is waiting on their Mac. You can run several at once, each with its own link. When `enrol` prints `Joined`, agents there find these instructions with `agent-keyring skill` and use Agent Keyring the same way as on the Mac. If the user denies it, `enrol` stops at once with `Josh denied adding this computer.` and any reply they wrote: do what the reply says, or stop and ask them. If nobody answers, `enrol` says so after ten minutes: tell the user, and make a new link only if they want to try again. If `enrol` says the computer has no Tailscale address, Tailscale is not running or not signed in there: tell the user.

**5. Optional browser extension,** only if the user asked for it. Ask which browser user-data directory they want to connect, register the native messaging helper only for that profile:

```sh
agent-keyring install --browser-profile "/path/to/Browser/User Data"
```

Then tell the user to load the unpacked extension once from `/Applications/Agent Keyring.app/Contents/Resources/AgentTools/BrowserExtension` in that browser profile (`chrome://extensions` with Developer mode on).

**6. The iPhone and Apple Watch,** if they want them. Tell the user to open Agent Keyring on their iPhone: it finds its invitation through iCloud Keychain, and a request to add it appears on the Mac. Then to open Agent Keyring on their Apple Watch, after the iPhone: the request to add it appears on the iPhone. You cannot install the apps or see whether these joined. Requests from other computers reach only the iPhone and Apple Watch, so those computers can ask once the iPhone has joined.

**7. Finish with one message:** which computers are set up, what the user still has to do on the iPhone, Apple Watch or browser extension, and for each computer left out, what it needs.

## When it doesn't work

- **Denied.** The user said no, and any reply they wrote is printed word for word. Do what it says, or stop and ask them. The same password can be asked for again after a minute; after a second denial in a row, five minutes; after more, fifteen. The message says until when. Don't wait it out to ask again for the same thing: change what you do first.
- **Unanswered.** Nobody answered in time. Tell the user, and try again when they are back, not in a loop. If they may be asleep or driving, say it in their words: "Vibe coding late at night? If Sleep or Driving Focus is on, Apple holds back notifications unless Agent Keyring is allowed in that Focus." On a Mac, `lease` prints this itself while it waits if a Focus is on.
- **Expired or released.** Lease again for the same task. Automatic logins don't ask; others ask once.
- **The page isn't the saved site.** You are not where the login belongs. Don't work around it.
- **Fields not found or ambiguous.** Inspect the page again and pass better selectors. This never asks the user again.
- **Clearing failed.** A value may still be on the page. Don't read the fields back; close the tab with your browser tools.
- **The site rejects the password.** The user's saved password is probably out of date. Tell them, and don't retry it.

- **Agent Keyring itself got in your way.** If it was annoying, confusing or broken, run `agent-keyring complain --summary "one line" --command "what you ran"`, with any detail on standard input and never a password, then carry on with your task. It goes to whoever builds Agent Keyring, not to the user.

`agent-keyring --help` describes every command, option and exit code.
