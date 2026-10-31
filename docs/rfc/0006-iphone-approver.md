---
written_by: AI (Claude Opus 5.5 and GPT-6 Astra, 2026-10-31)
status: reviewed; independent phone work can build; identity/rule handover and authority choice remain open
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

## Decisions before cutover

These stay open until he answers. Nothing in the build slices depends on the
answers except the final cutover step. Build against isolated fixtures while
they remain open; do not activate two competing production authorities by default.

### 1. How Touch ID on the MacBook works once the iPhone holds the strong copy

| Option | What happens | Protection | Cost |
| --- | --- | --- | --- |
| **A. Two copies** | The MacBook keeps its own copy and approves with Touch ID as today; the iPhone has its own | The iPhone's copy is protected by Face ID and the Secure Enclave. The MacBook's copy has today's protection, which is weaker: software that controls the MacBook could misuse it | Nothing changes at the keyboard |
| **B. iPhone only, Touch ID requests it** | The MacBook keeps no passwords. Touching the sensor sends a signed approval; the iPhone must then seal the login | Only the iPhone can open passwords | The iPhone must be reachable and awake enough to act. If its key needs Face ID, Josh touches the sensor and then looks at the phone, so Touch ID alone is no longer enough |
| **C. iPhone only, MacBook shows requests** | The MacBook panel shows the request; Josh approves on the iPhone | Only the iPhone can open passwords | Touch ID approval at the keyboard goes away; independent Watch approval remains unproved |

Recommendation: ship release 4 as **A**, because Josh asked not to break Touch
ID, and offer B or C later if he wants the stronger arrangement. Option B
needs a device proof (whether the iPhone can seal reliably from a background
wake) before it can be offered honestly.

### 2. Taking the Mac mini off iCloud Keychain

Agents administer the mini, and with iCloud Keychain on it, Apple Passwords is
potentially reachable there without Agent Keyring. This was not tested with a
real password. Josh agreed the direction, but cutover and treatment of retained
local copies remain to be confirmed. The recommendation is to turn it off on
the mini once the iPhone path is proven, and to check what local copies remain
afterwards. This is Josh's change to make.

### 3. iPhone installation and updates

Developer Mode and the update route remain Josh's decision. The recommendation
and its limits are below; development can continue without changing that setting.

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

1. The relay sends an Apple push that says only that a request is waiting,
   after Josh's configurable escalation delay. Preserve his existing setting;
   new setups default to two minutes. Cancel it if the request is answered or
   ends first, and retain the scheduled time across restarts. Registration
   carries this preference; the delay must fit inside the pending deadline.
2. Josh taps it. The app opens, fetches every pending request from the relay
   (the push is only a wake-up; Apple may drop or merge pushes), and shows the
   request.
3. Approve: the target is one Face ID for opening the login and signing, using
   one authentication context for that explicit action. This is a device proof,
   not established by creating two biometric keys. The app builds
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

Before R4.2 publishes an index or R4.5 joins the live setup, define the login-ID
mapping and rule handover. `SnapshotMerger` currently assigns a fresh UUID when
there is no previous local match. Independent Mac and iPhone imports therefore
do not automatically produce the same login IDs. The same code on both devices
does not fix this. Match using the Apple source identity where stable, preserve
existing public IDs through an authenticated mapping, and surface ambiguous
matches without guessing or transferring Automatic rules.

The authority choice also needs one rule-owner contract: which device's rules
and index are current, how revisions are compared, and what a stale device may
approve. Two independent publishers must not overwrite each other's index or
turn a phone's Blocked login back into Automatic. During development keep the
Mac's working setup and the phone fixture setup separate. If Josh selects two
live copies, settle their synchronization before cutover; do not infer consent
from the recommendation for option A.

### Losing the phone

Josh's logins live in Apple Passwords, so recovery is a fresh setup:

1. Install the app on the new iPhone and pair it with a surviving approver.
   If the lost phone was the only approver, perform fresh setup and enrol the
   machines again. The relay cannot authorize its replacement.
2. Export from Passwords.
3. Rules: the relay keeps the last signed rule list; the new phone shows it
   through the existing review-before-apply screen.
4. A surviving trusted approver removes the lost phone's key. Without one,
   new setup establishes new trust; an untrusted replacement phone cannot sign
   itself into the old setup.

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
  that machine receives that login. The deadline stops new compliant deliveries;
  it cannot make an already received password expire.
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
| R4.4 | Terra | Relay push: APNs registration, persisted configurable delay, a stable collapse ID for the recipient/login across retries, matching gateway to the build | Answer at the Mac before the delay: no phone push; reconnects do not stack notifications or reset the delay |
| R4.5 | Sol | Approver key set and enrolment transfer (MacBook signs the phone in; phone trusts machines the MacBook enrolled) | A machine enrolled in release 3 is approved from the phone with no re-enrolment |
| R4.6 | Sol | Automatic publishing to the relay key, and republishing after each import or rule change | An Automatic login fills with the MacBook and the iPhone both off |
| R4.7 | Opus | Phone screens wired to real backends (RFC 0007) | The designed states render from real requests |
| R4.8 | Josh, with an agent | Cutover per the Touch ID decision; Developer Mode and mini iCloud Keychain changes if he chooses | His decisions are applied and checked |

Prioritize R4.1's real-device proof because import is a dependency, while R4.2,
R4.3 and the screens can be built with clearly marked fixtures in parallel.
Josh's absence blocks the physical proof, not the independent implementation.
R4.5 and R4.6 also need the outstanding contracts in RFC 0005 before activation.

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
