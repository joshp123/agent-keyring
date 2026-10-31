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

## Where agents send requests

Josh hasn't decided whether agents on other machines should ask the MacBook
directly over Tailscale.

- **For the laptop-shut case it doesn't matter.** A shut MacBook cannot answer,
  so something always on has to: the mini. Remote agents therefore need the
  mini's address whatever he decides.
- **If he chooses direct:** the client asks the MacBook first and the mini when
  the MacBook doesn't answer. Two addresses, one fallback rule.
- **If he doesn't:** agents always ask the mini, which passes requests to the
  MacBook when it is awake. One address.

The design holds either way. Direct-only, with nothing on the mini, does not
meet the goal: it fails whenever the lid is shut.

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
| S4 | Client fallback, only if Josh chooses direct requests | With the MacBook shut, the client reaches the mini without a configuration change |

## Device proofs

On the real MacBook, iPhone and mini, with test logins only:

- Lid shut: an Automatic login and an Ask login each complete a sign-in from an
  agent on the mini.
- One Face ID both opens the login and signs the answer.
- Rule change from Automatic to Ask: the mini stops delivering it at once.
- Phone replaced: the new phone gets its copy at pairing and the old one's key
  is removed.

## Josh's decisions

1. Whether agents on other machines ask the MacBook directly over Tailscale.
   This design works either way.
2. Whether to take the mini off iCloud Keychain. Until he does, Apple Passwords
   is readable on the mini anyway.
3. Whether to turn Developer Mode off on the iPhone, so only a build he
   installed can use the phone's key.
