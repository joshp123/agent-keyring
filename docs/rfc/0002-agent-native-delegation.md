---
written_by: ai (Claude Opus 5.5, 2026-10-12), from Josh's steering, revised after a Fable review; Josh's words are quoted and win where this differs
---

# Agent Keyring 2: password delegation that just works for agents

## What it does

You ask an agent to do something. It needs a login. Agent Keyring finds the
login in its mirror of your Apple Passwords and checks your rule for it. If the
rule says ask, it asks you: on the Mac if you are there, on your iPhone if you
are not. Then Agent Keyring itself fills the credential into the sign-in form
the agent has open, in any browser. The agent never holds the password. It just
carries on.

Josh, 9 July: "when codex needs a password for something, it can *just work*
and find the necessary passwords/credentials, and just do the thing, without
me." Josh, 12 October: "it should Just Work in all the browsers that claude can
drive."

## What "best" means here

- 1Password for Claude fills without revealing, but only in Claude in Chrome,
  only with 1Password, and only with a Mac prompt.
- Bitwarden Agent Access hands the agent plaintext and has no revocation.
  Agent Keyring sends credentials to cloud agents only through a fill
  component, never to the model.

Agent Keyring will fill without revealing in every browser and for every agent,
approve from the iPhone when Josh is away, keep standing per-login rules
(including allow automatically), and run free on iCloud Passwords.

## What we keep from Josh's steering

- iCloud Passwords stays the source of truth; Agent Keyring mirrors it. No
  1Password migration.
- Rules per login: allowed automatically, ask each time, blocked. Default is
  ask; "eventually when we build trust" more become automatic.
- A proper Unix CLI: "do one thing and do it well", human-first output, no JSON.
- "NOT tightly couple our tool to the browser implementation." Fill works by
  reading the focused field and the page address through macOS Accessibility,
  not through any browser's internals.
- The rules must not be editable by agents ("needs to require sudo to edit tho
  otherwise agents can just hack it").
- Two clicks per approval is "kinda annoying if agents are using it a lot".
- The example.com login stays in the app for screenshots; the AI rules prompt
  stays a first-class feature.
- Passkeys are parked, not dropped.
- Free-text `find` and listing ("host doesn't always match the actual url e.g.
  amazon vs aws").
- Future: cloud agents (Grok bot, Muse), "with appropriate security".

## Product shape

### 1. Fill, don't reveal

- **`agent-keyring fill <field> <site>`**, the universal path.
  - The agent focuses the field in any visible browser (Safari, Chrome,
    Claude's built-in pane, Codex's browser), then runs `fill`.
  - The Agent Keyring app checks, in order:
    1. the screen is unlocked
    2. the frontmost app is a supported browser, verified by its code signature
       rather than its bundle ID, and the page address of the focused field's
       own document matches the saved site
    3. the focused element is a text field, and for passwords a secure text
       field.
  - It then types the value. It never presses Return; the agent clicks the
    sign-in button itself.
  - The agent learns only "filled" or why not.
  - This is how 1Password's Universal Autofill works. It needs one
    Accessibility permission. The checks and the typing run in a small
    embedded helper outside the App Sandbox, because sandboxed apps cannot use
    Accessibility; the main app and the extension stay sandboxed.
  - The page address must be read from the field's own document. If it cannot
    be read, fill refuses and points the agent to agent-browser. There is no
    fallback to the agent-supplied site.
  - Grants are per action: approving a fill never unlocks `acquire`.
  - Before typing, modifier keys are cleared and everything is re-checked. If
    focus changes while typing, fill reports it instead of "filled".
- **agent-browser adapter**, for headless work: a `credential.read` plugin, so
  `agent-browser auth login <site> --credential-provider agent-keyring` signs
  in with agent-browser checking the origin. agent-browser's protocol has no
  one-time code field, so codes use `fill code` in a visible browser, or
  `read` piped straight into agent-browser's type command. We propose a code
  field upstream.
- **`acquire`/`read`/`clear`** stays for programs that need a value, now with an
  expiry. `copy` is removed: every process and clipboard history can read the
  clipboard.

### 2. Requests and approvals

- **The app owns each request for 10 minutes,** independent of the CLI process.
  The CLI waits and prints "Waiting for your approval on your iPhone" every 30
  seconds. If the agent's harness kills it, re-running the same command picks
  up the approval.
- **Grants:** an approval covers one login, all its fields, for 30 minutes,
  held in memory. The menu bar has "End all grants". (Josh's June idea was one
  approval for all agents for 30 minutes. Per-login is the default because it
  keeps "ask each time" meaningful. Switch to session-wide if approvals prove
  annoying.)
- **Routing:** if the Mac is locked or its display is asleep, the iPhone is
  asked at once and the Mac prompt is not started. Otherwise the Mac asks
  first and the iPhone is asked after a delay Josh sets (default 2 minutes).
- **The agent always knows what Josh is being asked and when,** so it can tell
  him in chat instead of hanging. Each step is a plain line on stderr with an
  exit status at the end, for example:
  - "Asked Josh on his Mac at 02:41; will ask on his iPhone at 02:43."
  - "Asked on iPhone at 02:43."
  - "Approved at 02:44."
  - "No answer by 02:51; request expired."
- **Honest failures,** each with its own exit code and sentence: you declined,
  nobody answered, the request expired, the Mac is locked and no iPhone is
  paired, the rules changed.
- The Mac approval UI is the native Touch ID or Watch sheet with its reason
  text. Nothing else.

### 3. Tamper-evident rules

- On every save, the app signs the rules file with a Secure Enclave key whose
  use needs Touch ID.
- On load it verifies the signature. A missing signature or an altered file
  fails closed: nothing is released until Josh confirms the rules in the app.
- The paired iPhone's public key lives in the same signed store.

### 4. The iPhone app

- **Pairing:** the Mac shows a QR code holding a one-time secret. The iPhone
  scans it, creates a Secure Enclave key, and sends its public key
  authenticated with that secret. The Mac confirms with Touch ID and stores the
  key in the signed store.
- **Channel:** CloudKit in Josh's private iCloud database.
  - The Mac writes a request record; site and account go in encrypted fields.
  - A CloudKit subscription sends a visible, time-sensitive notification. It
    never uses silent pushes, which Apple coalesces.
  - The iPhone writes the decision back. While a request is pending, the Mac
    polls the decision every 2 seconds, with push as a wake-up.
- **One tap:** the notification shows agent, site and account, with Approve and
  Deny actions. The device unlock (Face ID) is the presence check. The handler
  signs the request with a Secure Enclave key that needs no further biometric
  prompt. This must be proved on Josh's iPhone first. The fallback is opening
  the app with Face ID per approval, which is two taps.
- **Verification:** the iPhone signs request ID, site, field, a one-time value
  and expiry. The Mac verifies the signature against its own copy of the
  request, never the CloudKit copy. Request IDs are single-use.
- **Actions:** Approve, Deny, Block this login. The iPhone never receives
  passwords.
- **Distribution:** direct install with the paid team's development profile,
  which lasts a year. No TestFlight. The Mac app embeds a provisioning profile
  for CloudKit, re-shipped with every Sparkle update; deploy the CloudKit
  schema to production before testing.

### 5. Sync

- **First, fix import.** It has failed since July (Josh reported it on 16 July
  and 17 September); the mirror is 93 days old. Do it live with Josh before
  anything is proved on real data. Candidates:
  - a duplicate login makes the merge reject the whole import
  - two extension registrations share one ID
  - the macOS 27 hand-off.
- **Scheduled check:** when the mirror is older than 7 days, Agent Keyring
  sends a daytime notification. Its action opens Apple Passwords and states the menu choice
  (File → Export All Items to App → Agent Keyring); macOS offers no way to
  open that export directly.
- **Sync on failure:** when a site rejects a filled login, the agent runs
  `agent-keyring sync <site>`. That marks the login stale and sends the same
  prompt.
- The mirror's age shows in `find`, `status` and every approval.
- Capturing passwords as they are saved is out: Josh does not want extra
  approvals.

### 6. Install

`agent-keyring install`:
- sets up the Claude Code and Codex skills
- prints the minimal AGENTS.md snippet Josh asked for in July
- registers the agent-browser plugin.

## Fixes (from the reviews)

- Policy is checked again after approval. Blocking a login clears its
  outstanding buffers.
- Buffers expire after 5 minutes, end on `clear`, and end at once when their
  login is blocked. They are not tied to the requesting shell, because agents
  run each step in a fresh shell and the value must survive until it is
  entered. One-time code buffers hold only the current code; the seed never
  leaves the app.
- Approval requests are serialised.
- Site matching:
  - the page host equals the saved host or is a subdomain of it
  - `http` saved logins match their `https` pages
  - `--account` filters before ranking.
- One-time codes are generated at fill time. Logins that hold only a code keep
  their account name.
- Import:
  - a duplicate login no longer rejects the whole import
  - old encrypted generations are pruned
  - `status` and `find` no longer decrypt passwords.
- The example login sits behind a setting, on by default, and is excluded from
  counts.

## Delete

- The approval-window positioner.
- `copy`.
- The README video renderer and the docs preview in the product.
- Legacy-install migration.
- Unused delta and import-scope machinery.
- Environment-variable overrides for the app path and bundle ID.
- Leftovers from the removed browser module.

## Cloud agents (designed now, built after)

The risk profile and open decisions are in `0003-cloud-agents-risk.md`.

Grok bot and Muse work in their own cloud environments, so the credential has
to reach them. The design keeps that delivery as narrow as possible. In order
of preference:

1. **A session, not the password.** Where the site allows it, the Mac signs in
   and hands the cloud agent's browser the signed-in session. The password
   stays home, and the session expires and is revocable.
2. **The password, sent to the cloud agent's browser and never to the model.**
   The cloud environment runs a small Agent Keyring component (the same
   agent-browser plugin). The Mac sends the credential encrypted end to end to
   that component only. It fills the form and discards the value.
3. **API keys through a relay.** The agent's API calls go through a relay
   under Josh's control that attaches the key, so the key stays home.

Security around all three:
- Each cloud agent is paired once with its own key, signs every request, and
  is revocable from the iPhone.
- Every cloud request needs iPhone approval, with a short binding code shown
  both in the agent's chat and on the phone. "Allowed automatically" applies
  to local agents only.
- A release is bound to one request and one site, single-use and
  short-lived, and logged.
- Follow Bitwarden Agent Access (pairing tokens, Noise encryption through a
  relay that cannot read traffic) rather than inventing a protocol.

The request object already carries agent identity, request ID, credential ID,
origin, fields and expiry, so this phase adds an approval provider, a
paired-agent registry and the remote component, not a rewrite.

## Execution plan

GPT-6.1 Sol implements each slice in its own worktree with a tight brief.
Opus checks every slice against the real flow, and Fable reviews before merge
to main. Every fill proof runs `script/check_login_artifacts.py` over the agent
transcript to show the secret never appeared.

| Lane | Slice | Human proof |
| --- | --- | --- |
| A | Core fixes | Tests pass; CLI permutations read raw |
| A | Requests, approvals, routing, signed rules; delete the positioner | Locked Mac: the request waits, then succeeds; a grant covers a second request; editing the rules file by hand fails closed |
| B | iPhone app: pairing, CloudKit channel, one-tap signing spike first | Mac locked: approve on the iPhone from bed and the waiting CLI succeeds; latency measured |
| C | `fill` spike (address read-back in Safari, Chrome, Claude's pane), then `fill` | The agent fills the example login on a local test page in each browser; transcript scan clean |
| C | agent-browser adapter | Headless sign-in to the test page; transcript scan clean |
| D | Import fix, with Josh | A new Apple Passwords login appears after one export |
| D | Scheduled check, `sync`, install, deletions, release | Sparkle update installs; the iPhone app runs from Josh's phone |

Follow-ups found in review, for later slices:

- If the screen locks during a prompt, return to waiting for unlock within the
  same 10-minute request, instead of reporting "interrupted".
- Treat a sleeping display as locked when routing to the iPhone.
- Split `main.swift` and `MirrorAppModel.swift`; both are over 500 lines.
- Clear a plugin request's buffers when it returns "pending", so no value waits
  unread for 5 minutes.

Lanes A, B and C have separate write-sets and run in parallel. Lane B
integrates after lane A's approval slice. Lane D needs Josh at the Mac for the
import fix.
