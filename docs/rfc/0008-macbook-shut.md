---
written_by: AI (Claude Opus 5.5, 2026-11-01)
status: design for review; no code yet
depends_on: 0004, 0005, 0006
replaces: the "Later: answering with the MacBook shut" section of 0006
---

# RFC 0008: logins with the MacBook shut

## The goal

Josh, 30 October: any agent should always be able to ask for a password, "no
matter where you are or which machine is on", and the conclusion was
"probably run it on the mac mini".

Today the MacBook is the only place a password can come from. Close the lid and
every request waits, including Automatic ones such as a daily bank download.

## The design

Each rule has one place it is served from when the MacBook is shut:

| Rule | MacBook awake | MacBook shut |
| --- | --- | --- |
| Automatic | MacBook delivers, no prompt | **The Mac mini delivers**, no prompt |
| Ask | Touch ID, or the iPhone after the delay; MacBook delivers | **The iPhone** asks Josh, then delivers itself |
| Blocked | Refused | Refused |

That needs two new copies, each holding only what its job needs:

- **The mini holds the Automatic logins.** The MacBook sends them to the mini
  whenever an import or a rule change touches one. The mini then approves and
  delivers Automatic requests by itself, under the same rules and the same
  list of approved machines. Nothing else is installed or imported on the
  mini.
- **The iPhone holds the Ask logins.** The MacBook sends them to the phone,
  sealed to a key in the phone's Secure Enclave that needs Face ID to use.
  When Josh approves on the phone, it opens that one login and sends it to the
  machine that asked.

Both copies come from the MacBook. There is still one import, on the MacBook,
and no import on the phone or the mini. A new or replaced phone gets its copy
when it pairs.

When the MacBook is awake nothing changes from release 4. The phone delivers
an Ask login itself whenever it holds it, so the earlier "phone approves, Mac
delivers" path becomes a fallback for a login the phone doesn't hold yet.

## What each copy exposes

| Copy | Holds | Who can read it |
| --- | --- | --- |
| Apple Passwords, through iCloud Keychain | Everything | Whoever controls any device signed in to it. Today that includes the mini, where agents are administrators. This exists already, without Agent Keyring |
| MacBook's Agent Keyring copy | Everything | Whoever controls the MacBook's user account, as today |
| **Mini's Agent Keyring copy** | **Automatic logins only, including their two-factor seeds** | **Anyone who administers the mini, and that includes agents.** Moving a login off Automatic deletes it from the mini but cannot take back what was already read |
| **iPhone's copy** | **Ask logins only, sealed** | Only with Josh's Face ID. A replaced development build of the app could ask for Face ID, which is why Developer Mode matters (below) |
| A delivery to an agent's machine | One login, for one task | That machine, which can keep it. The relay in between cannot open it |
| Blocked logins | Nothing new | Only Apple Passwords and the MacBook's copy |

Plainly: an Automatic login is trusted to anyone who controls the mini. That is
what "Automatic, with the laptop shut" means. Logins that must not be exposed
that way stay Ask.

The mini's copy adds nothing while iCloud Keychain stays on there, because
Apple Passwords is already on the mini. It only becomes the boundary once the
mini is taken off iCloud Keychain, which is Josh's decision.

## One place to ask

Agents on other machines always send requests to the mini. The mini passes Ask
requests to the MacBook when it is awake and to the iPhone when it isn't, and
answers Automatic ones itself. Agents on the MacBook keep using the MacBook
directly, as today.

This is simpler than asking the MacBook directly over Tailscale and falling
back to the mini:

| | One place to ask (the mini) | MacBook first, mini as fallback |
| --- | --- | --- |
| Where a task's approval and deadline live | One record, on the mini | Two places, which must agree |
| Lost reply, then a retry | The retry rejoins the same record, as now. No second prompt | The MacBook may have accepted it while the client retries at the mini. Avoiding a second prompt means the two must share lease state |
| Lid closes mid-task | The approved lease and its sealed login are already on the mini, so the task carries on until its deadline | The lease is on the MacBook, which is now asleep. The task must ask again |
| Request waiting when the lid closes | The mini sees the MacBook drop off and asks the iPhone at once | The client has to notice and resend to the mini |
| What the mini can read | Which machine asked for which login and when, and the Automatic logins. Ask logins pass through sealed to the receiving machine, so it cannot open them | The same whenever the lid is shut, so in practice no less |
| Cost | If the mini is down, remote agents wait even when the MacBook is awake | Remote agents work without the mini only while the MacBook is awake |

Asking the MacBook directly removes nothing: the mini path has to exist for the
shut lid, so direct requests are a second path with its own retry rules on top.
The one thing it buys is working through a mini outage while the MacBook is
awake. The recommendation is one place to ask.

Who asks the iPhone stays as in release 4 while the MacBook is connected: the
Mac asks after Josh's delay, or at once if its screen is locked. If the MacBook
is not connected to the mini, the mini asks the iPhone at once.

## Limits

- Ask with the lid shut needs Josh to answer on the phone, and the phone to
  reach the tailnet. That is the point of Ask.
- Notifications need an Apple push key. Without one, Josh sees a request only
  when he opens the app.
- A login added or changed in Apple Passwords reaches the copies at the next
  MacBook import, as it does today.
- The mini must be up. If it or the home internet is down, remote agents wait.

## What this removes from earlier plans

- Importing from Apple Passwords on the iPhone. It was unproven and Apple's
  export is hard to automate; the phone gets its copy from the MacBook instead.
- Matching login IDs between two separate imports. With one import there is
  one set of IDs.
- Moving rule ownership to the phone. The MacBook stays the owner.
- A separate Agent Keyring on the mini with its own import of a few logins.
  The mini's copy is part of the same keyring, rules and machine list.

## Contract changes (for the build, after review)

All additions to `relay.proto` and `bundle.proto`:

- The phone's `ApproverKey` gains its Face ID protected key-agreement public
  key, so the MacBook can seal logins to it.
- A phone copy message: the Ask logins sealed to that key, with a revision.
  The MacBook publishes it through the relay; the phone fetches it.
- A decision signed by the phone's key with `authority = HUMAN` carries a sealed
  login, like the MacBook's own approvals.
- The Automatic copy on the mini already exists in the contract
  (`ConfigurationPublication.automatic_logins`, `GetAutomaticKeys`); it moves
  from "later" to this release.

## Build slices

| Slice | What | Done when |
| --- | --- | --- |
| S1 | Mini delivers Automatic logins: MacBook publishes them with each configuration; the relay approves and seals Automatic requests | With the MacBook shut, an agent on the mini gets an Automatic test login, and moving it to Ask removes it from the mini |
| S2 | Phone key and copy: Face ID key-agreement key; MacBook seals Ask logins to it on pairing and after each change | The phone holds the test logins; a re-import that changes one updates it and leaves the rest |
| S3 | Phone delivers: Face ID opens one login, the phone seals it to the machine that asked, signs, sends | With the MacBook shut and the phone on mobile data, one Face ID completes an agent's test sign-in |
| S4 | Mini asks the iPhone when the MacBook is not connected, including for a request already waiting when it drops off | A request waiting on the Mac panel reaches the phone as soon as the lid closes, with one prompt |

## Device proofs

On the real MacBook, iPhone and mini, with test logins only:

- Lid shut: an Automatic login and an Ask login each complete a sign-in from an
  agent on the mini.
- Lid closes during a task approved on the MacBook: the agent's next fill
  works without a new prompt, until the original deadline.
- Lid closes while a request waits on the Mac panel: the phone is asked once,
  and the task gets one approval.
- A reply lost on the way back to the agent: its retry returns the same lease,
  with no second prompt.
- One Face ID both opens the login and signs the answer.
- Rule change from Automatic to Ask: the mini stops delivering it at once.
- Phone replaced: the new phone gets its copy at pairing and the old one's key
  is removed.

## Josh's decisions

1. Whether agents on other machines always ask through the mini. Recommended,
   because the mini path must exist for the shut lid anyway and one path has
   one set of retry rules. Asking the MacBook directly would only help during
   a mini outage.
2. Whether to take the mini off iCloud Keychain. Until he does, Apple Passwords
   is readable on the mini anyway.
3. Whether to turn Developer Mode off on the iPhone, so only a build he
   installed can use the phone's key.
