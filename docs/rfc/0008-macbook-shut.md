---
written_by: AI (Claude Opus 5.5, 2026-11-01)
status: design, revised after review; no code yet
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

Agents on other machines always ask the Mac mini. Agents on the MacBook keep
asking the MacBook. One lease record per task, on whichever of those two the
agent asked, holds its approval and deadline, and every retry rejoins it.

| Rule | Remote agent (asks the mini) | Agent on the MacBook |
| --- | --- | --- |
| Automatic | The mini delivers, awake or shut | The MacBook delivers |
| Ask | Josh approves with Touch ID on the MacBook, or on the iPhone after his delay. Whoever holds the login delivers (below) | Touch ID, or the iPhone after the delay; the MacBook delivers |
| Blocked | Refused | Refused |

For an Ask login approved on the iPhone, the phone delivers it itself if it
holds an up-to-date copy. If it doesn't, the phone's approval goes to the
MacBook, which delivers it as in release 4, if it is awake. Either way it is the
same lease and the first committed answer wins.

That needs two copies, each holding only what its job needs, and both coming
from the MacBook's one import:

- **The mini holds the Automatic logins**, so it can serve them unattended.
- **The iPhone holds the Ask logins**, sealed to a key in its Secure Enclave
  that needs Face ID. If the copy never arrives or goes stale, the phone still
  works as an approval device while the MacBook is awake.

There is no import on the phone or the mini, no second set of login IDs, and
the MacBook stays the owner of the rules.

## How the copies stay right

The copies travel in the publication the MacBook already sends to the mini
whenever an import, rule change or machine change is confirmed (RFC 0005).

- The signed configuration already lists every login and its rule. It gains a
  hash of each sealed phone login, next to the existing hashes of the mini's
  Automatic logins. So the MacBook's signature covers exactly which logins each
  copy holds, at which revision.
- The phone accepts a copy only with a valid configuration signed by the
  MacBook, at a revision no lower than it has already seen, with every hash
  matching. An older copy replayed later is refused.
- The MacBook shows "Applying" until the mini acknowledges the publication.
  From that moment the mini serves only the new configuration. The phone picks
  up its copy the next time it connects; until then it treats any login whose
  copy is behind the configuration as not held, and falls back to approval
  only.

## When a rule changes

A change takes effect at the mini when it acknowledges the publication, not
before. Until then the mini may still serve under the previous configuration;
the MacBook says "Applying" for that period.

- **Automatic to Ask, or to Blocked:** the mini deletes its copy of that login
  and stops serving it when it commits the new configuration. It cannot take
  back a password it already delivered or that someone already read on the
  mini.
- **To Blocked:** the mini refuses any delivery of it, including one the phone
  signs from an older copy. The phone deletes its copy when it next connects.
- **New login, or changed password:** it reaches the copies at the next
  MacBook import and confirmation, as today.

## What each copy exposes

| Copy | Holds | Who can read it |
| --- | --- | --- |
| Apple Passwords, through iCloud Keychain | Everything | Whoever controls any device signed in to it. Today that includes the mini, where agents are administrators. This exists already, without Agent Keyring |
| MacBook's Agent Keyring copy | Everything | Whoever controls the MacBook's user account, as today |
| **Mini's copy** | **Automatic logins only, with their two-factor seeds** | **Anyone who administers the mini, and that includes agents.** Removing a login from Automatic deletes it from the mini but cannot take back what was already read |
| **iPhone's copy** | **Ask logins only, sealed** | It opens only after Face ID. Whether an app update could quietly gain access to that key is not yet proven, so this is not stated as a guarantee |
| A delivery to an agent's machine | One login, for one task | That machine, which can keep it. The mini cannot open Ask deliveries |
| Blocked logins | Nothing new | Only Apple Passwords and the MacBook's copy |

Plainly: an Automatic login is trusted to anyone who controls the mini. That is
what serving it unattended means. Logins that must not be exposed that way stay
Ask.

The mini's copy adds nothing while iCloud Keychain stays on there, because
Apple Passwords is already on the mini. It only becomes the real limit once the
mini is taken off iCloud Keychain.

## Why one place to ask

The mini must answer when the lid is shut, so it is on every remote path anyway.
Sending remote agents to the MacBook first would add a second lease store and
its own retry rules on top. The one thing it would buy is working through a
mini outage while the MacBook is awake.

With one place to ask:

- a lost reply is retried against the same lease, so nobody is prompted twice;
- a task approved on the MacBook keeps working after the lid closes, because
  its lease and sealed login are on the mini;
- a request waiting on the Mac panel when the lid closes goes to the phone,
  because the mini sees the MacBook drop off and asks the phone at once.

While the MacBook is connected, the Mac still decides when to ask the phone:
after Josh's delay, or at once if its screen is locked.

The cost: if the mini is down, remote agents wait even when the MacBook is
awake.

## Limits

- Ask with the lid shut needs Josh to answer on the phone, and the phone to
  reach the tailnet.
- Notifications need an Apple push key. Without one, Josh sees a request only
  when he opens the app.
- If the mini or the home internet is down, remote agents wait.

## Contract changes

All are additions. Signing roles stay as narrow as now.

- The phone's `ApproverKey` gains its Face ID protected key-agreement public
  key. The MacBook signs it into the key set at pairing, as now.
- `Configuration` gains `sealed_phone_login_sha256`, alongside
  `sealed_automatic_login_sha256`. `ConfigurationPublication` gains the sealed
  phone logins, using the same sealed-login message as the Automatic ones.
  The relay hands the latest publication's phone logins to the phone.
- A decision with `authority = HUMAN` may be signed by a PHONE key, as well as
  by the MacBook's key, when the phone delivers a login itself. This changes
  nothing else about the phone's powers: it still cannot sign configurations or
  key sets.
- The configuration's Automatic signing key becomes the mini's key for remote
  Automatic requests. The existing `GetAutomaticKeys` and
  `ConfigurationPublication.automatic_logins` already cover this.

## Build slices

| Slice | What | Done when |
| --- | --- | --- |
| S1 | The mini serves remote Automatic requests, awake or shut, from the Automatic logins in each publication | With the MacBook shut, an agent on the mini gets an Automatic test login; after a change to Ask is acknowledged, the mini refuses it |
| S2 | Phone copy: the key, sealed Ask logins in the publication, hashes in the signed configuration, revision checks on the phone | The phone holds the test logins; a re-import that changes one updates it; an older copy replayed to the phone is refused |
| S3 | The phone delivers: Face ID opens one login, the phone seals it to the machine that asked and signs a HUMAN decision; approval-only when it has no current copy | With the MacBook shut and the phone on mobile data, one Face ID completes an agent's test sign-in |
| S4 | The mini asks the phone when the MacBook is not connected, including for a request already waiting when it drops off | A request waiting on the Mac panel reaches the phone as soon as the lid closes |

## Device proofs

On the real MacBook, iPhone and mini, with test logins only:

- Lid shut: an Automatic login and an Ask login each complete a sign-in from an
  agent on the mini.
- Lid closes during a task approved on the MacBook: the next fill works
  without a new prompt, until the original deadline.
- Lid closes while a request waits on the Mac panel: the phone is asked, and
  the task gets one approval.
- Lost reply, both ways: once where the mini had accepted the request before
  the connection dropped, and once where it had not. Each retry ends with one
  lease and no second prompt.
- Mac and phone answer the same request at nearly the same time: one lease is
  granted; the other device shows it was answered elsewhere. A notification
  that arrives twice is not a second approval.
- One Face ID both opens the login and signs the answer.
- Phone with no copy, or a stale one: it approves, and the MacBook delivers if
  awake.
- Phone replaced: the new phone gets its copy at pairing and the old one's key
  is removed.

## Josh's decision

Whether to take the mini off iCloud Keychain. Until he does, Apple Passwords is
readable on the mini anyway, so the mini's Automatic copy adds no new exposure.

Separately, before anyone claims that only Josh's installed build can use the
phone's key, that needs proving: turning Developer Mode off alone does not
establish it.
