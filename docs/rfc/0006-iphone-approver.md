---
written_by: AI (Claude Opus 5.5, 2026-10-31)
status: proposal for implementation; one decision pending for Josh (Touch ID); Astra review pending
depends_on: 0004, 0005
related: 0007 (approval UI); docs/rfc/README.md has the build plan
---

# RFC 0006: the iPhone as approver

## What ships

Josh can answer any agent's request on his iPhone, wherever he is, with the
MacBook shut. The iPhone imports his logins straight from Apple Passwords,
keeps them encrypted under a key in its Secure Enclave, and seals each
approved login to the receiving machine through the relay from RFC 0005.
Touch ID at the MacBook keeps working throughout this release.

This is release 4. The designs in `docs/design/` (branch
`t3/agentkeyring-app-design`) are the starting point for the screens; RFC 0007
keeps them separate from this logic so design changes don't touch it.

## Two decisions for Josh

These stay open until he answers. Nothing in the build slices depends on the
answers except the final cutover step.

### 1. How Touch ID on the MacBook works once the iPhone holds the strong copy

| Option | What happens | Protection | Cost |
| --- | --- | --- | --- |
| **A. Two copies** | The MacBook keeps its own copy and approves with Touch ID as today; the iPhone has its own | The iPhone's copy is protected by Face ID and the Secure Enclave. The MacBook's copy has today's protection, which is weaker: software that controls the MacBook could misuse it | Nothing changes at the keyboard |
| **B. iPhone only, Touch ID requests it** | The MacBook keeps no passwords. Touching the sensor sends a signed approval; the iPhone must then seal the login | Only the iPhone can open passwords | The iPhone must be reachable and awake enough to act. If its key needs Face ID, Josh touches the sensor and then looks at the phone, so Touch ID alone is no longer enough |
| **C. iPhone only, MacBook shows requests** | The MacBook panel shows the request; Josh approves on the iPhone or the Watch | Only the iPhone can open passwords | Touch ID approval at the keyboard goes away |

Recommendation: ship release 4 as **A**, because Josh asked not to break Touch
ID, and offer B or C later if he wants the stronger arrangement. Option B
needs a device proof (whether the iPhone can seal reliably from a background
wake) before it can be offered honestly.

### 2. Taking the Mac mini off iCloud Keychain

Agents administer the mini, and with iCloud Keychain on it, Apple Passwords is
readable there without Agent Keyring. The recommendation is to turn it off on
the mini once the iPhone path is proven, and to check what local copies remain
afterwards. This is Josh's change to make.

## How it works

### Import and refresh

1. Josh opens Passwords on the iPhone and chooses to export to Agent Keyring.
   Apple's credential exchange starts only from the Passwords app and needs his
   authentication; no app can start or schedule it.
2. Agent Keyring receives the token, calls `importCredentials(token:)`, maps
   logins and code seeds, and merges them additively (the release 2 merge): a
   selected export updates and adds; items missing from it stay; a full export
   shows removals for Josh to confirm.
3. Each login is sealed to the phone's own Secure Enclave key-agreement key and
   stored in the app's container. Passkeys are not imported, as today.
4. The phone publishes a signed login index to the relay, so agents can `find`.

Refresh is the same export. There is no continuous sync: Apple offers no API to
read Passwords or learn that a login changed. The app shows the import age on
the approval screen, and asks for a refresh only when an agent reports that a
site rejected a saved password.

### Keys

| Key | Where | Use | Access control |
| --- | --- | --- | --- |
| Vault key | iPhone Secure Enclave, P-256 key agreement | Opens a sealed login | Face ID (current enrolment) on every use; created on this device and cannot leave it |
| Approver signing key | iPhone Secure Enclave, P-256 signing | Signs decisions and approver key sets | Face ID on every use |
| TLS key | iPhone Keychain, this device only | Mutual TLS to the relay | Device unlocked |

The Secure Enclave holds keys, not passwords: the passwords are sealed to the
vault key and stored as files. The existing phone signing key was created
without a biometric requirement; it is replaced, not reused.

### Approving

1. The relay sends an Apple push that says only that a request is waiting.
2. Josh taps it. The app opens, fetches every pending request from the relay
   (the push is only a wake-up; Apple may drop or merge pushes), and shows the
   request.
3. Approve: one Face ID covers opening the login and signing. The app builds
   the bundle (username, password, precomputed codes up to `not_after`), seals
   it to the receiver's enrolled key from its own records, signs the decision,
   writes it to a local outbox and sends it until the relay acknowledges.
4. A lost acknowledgement means a resend of the same signed decision, never a
   second Face ID.

Approve opens the app. A notification action that runs in the background
cannot show Face ID, so it cannot use these keys.

### Adding the iPhone to an existing setup

The MacBook is already a pinned approver (RFC 0005). Pairing the iPhone with
the MacBook by code lets the MacBook sign a new approver key set that includes
the phone. Receivers accept it because a key they pinned signed it. The phone
fetches the enrolled machines with the MacBook's signed approvals and trusts
those, so no machine needs re-enrolling.

### Losing the phone

Josh's logins live in Apple Passwords, so recovery is a fresh setup:

1. Install the app on the new iPhone and pair it with the MacBook (option A or
   B) or with the relay's existing approver.
2. Export from Passwords.
3. Rules: the relay keeps the last signed rule list; the new phone shows it
   through the existing review-before-apply screen.
4. The lost phone's key is removed from the approver key set, signed by the
   MacBook or the new phone after pairing.

If both the MacBook and the iPhone are lost or reset, each agent machine
enrols again by code. No backup system is added.

### Automatic logins

Automatic means no prompt. To approve without the MacBook or the iPhone
present, the relay needs to open those logins itself, so the phone publishes
them sealed to the relay's own key, code seeds included. Stated plainly:
anyone who controls the mini can read Automatic logins, and moving a login back
to Ask does not recall a copy already published. Changing a login to Automatic
says so on the screen.

## Protections and their limits

- **Ask and Blocked logins need Face ID on the iPhone to open.** The relay and
  the agent machines never hold the vault key. Limit: under option A the
  MacBook's copy keeps its weaker protection.
- **The iPhone checks requests against its own data.** It shows the site,
  account and machine from its own vault and enrolment records, and the agent's
  reason as a claim. Limit: if Josh approves a request he should not have,
  that machine gets that login until the deadline.
- **Only Josh's installed build should hold the vault key.** An app build signed
  by the same developer team inherits its keychain access. Developer Mode is
  currently on and the iPhone is paired for development, so a replaced
  development build could ask for Face ID and use the keys. Recommended: turn
  Developer Mode off after setup and install updates through TestFlight with
  automatic updates off, so each update is Josh's tap. This is Josh's setting
  to change, and it does not prevent a bad build being uploaded, only a silent
  install.
- **One-time code seeds stay on the iPhone** for Ask logins.

## Build slices

| Slice | Owner | What | Done when |
| --- | --- | --- | --- |
| R4.1 | Sol | Credential provider extension on the iPhone with credential exchange support; iOS target 26; import mapping shared with the Mac | A selected export of one test login reaches the app on a real iPhone |
| R4.2 | Sol | Phone vault: Secure Enclave keys with Face ID access control, sealed item files, additive merge, index publishing | Re-export of one changed test login updates it and leaves the rest |
| R4.3 | Sol | Phone approver: relay connection, pending fetch on open, decision checks against local data, sealing, signed decisions, outbox | Approve a remote request on cellular; drop the network after Face ID and restore it; one Face ID total |
| R4.4 | Terra | Relay push: APNs token registration, one wake-up per request with a collapse ID per lease, matching development or production gateway to the build | Overnight re-requests show one notification, not a stack |
| R4.5 | Sol | Approver key set and enrolment transfer (MacBook signs the phone in; phone trusts machines the MacBook enrolled) | A machine enrolled in release 3 is approved from the phone with no re-enrolment |
| R4.6 | Sol | Automatic publishing to the relay key, and republishing after each import or rule change | An Automatic login fills with the MacBook and the iPhone both off |
| R4.7 | Opus | Phone screens wired to real backends (RFC 0007) | The designed states render from real requests |
| R4.8 | Josh, with an agent | Cutover per the Touch ID decision; Developer Mode and mini iCloud Keychain changes if he chooses | His decisions are applied and checked |

R4.1 is the riskiest step, because the same Apple hand-off failed repeatedly on
the Mac before release 1. Build it first and prove it on the device before the
rest depends on it.

## Human proofs for release 4

All on the real iPhone; the simulator cannot show Face ID, credential exchange,
real pushes, Secure Enclave access control or Tailscale.

- Import a selected test login, then change it in Passwords and export again:
  the change arrives and nothing else is lost.
- A remote agent requests over the relay with the MacBook shut and the iPhone
  on mobile data; one Face ID approves; the agent completes the sign-in.
- Deny with a dictated reply; the agent receives the reply.
- Reboot the iPhone and the mini with requests pending: no duplicate prompts,
  no lost approvals.
- Another VPN active on the iPhone: record what happens to the tailnet, since
  only one VPN can use On Demand at a time.
- Touch ID at the MacBook still approves (option A), demonstrated before any
  cutover.
- Whether one Face ID can cover both opening the login and signing, or the app
  must ask twice. If twice, combine the steps or say so on screen.
