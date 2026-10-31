Written by AI on 2026.10.31 by model gpt-6.1-sol.

# iPhone vault: R4.2

Agent Keyring 0.4.0 (5) replaces the R4.1 receipt destination with encrypted
storage. The real import backend reports `.imported(count:at:)` only after the
vault commits; launch reads that count and date from the durable index. An old
R4.1 receipt does not count as saved logins. The designer's views are unchanged.

## Storage and keys

`AgentKeyringPhoneVault` seals each imported `MirrorItem` with ephemeral P-256
key agreement, HKDF-SHA256 and AES-GCM. The authenticated context binds the local
item UUID and ciphertext UUID. Each immutable `.sealed` file contains the
version, ephemeral public key and ciphertext. `manifest.plist` contains only
source identity, title, saved sites, account, code availability and file IDs.
Passwords and code seeds exist only in the ciphertexts and transient memory.
On open, the decrypted item must agree with its indexed metadata.

The phone's recipient key is `SecureEnclave.P256.KeyAgreement.PrivateKey`.
Its access control is `WhenUnlockedThisDeviceOnly` with `privateKeyUsage` and
`biometryCurrentSet`. The new signing key has the same control; its versioned
account never opens the legacy biometric-free signing key. Their device-wrapped
representations are stored as explicitly non-synchronizable, this-device-only
Keychain items. There is no software-key or passcode fallback in the phone app.
A missing key does not silently replace the key for an existing vault.

`Application Support/PhoneVault` is excluded from backup. The directory,
manifest, owner-index cache and item files use complete iOS file protection.
Imports encrypt with the public key, so retaining previous items does not open
them or request a biometric operation for every retained login.

The shared `SnapshotMerger` merges metadata and incoming items additively. The
vault writes the imported item files first and atomically replaces its manifest
last. Untouched item files remain unchanged. Cleanup follows the commit, and
its failure cannot turn a successful import into an apparent failure.

## MacBook IDs and rules

`PhoneVault.refreshOwnerIndex(owner:getIndex:)` is the connection boundary for
R4.3/R4.5. The caller gets `SignedIndex` through GetIndex over its pinned relay
connection and supplies the owner established by the verified ApproverKeySet.
R4.2 does not pair, contact the live relay or publish a competing index.

The vault verifies the owner's P-256 DER signature over the exact index bytes,
retains the highest valid revision on disk and rejects different index bytes at
the same revision. Fresh launches establish authority only after a successful
fetch and verification; the stored revision still prevents rollback.

Source identity matches take the Mac's login ID. Fallback requires the complete
saved-sites set and exact account to occur once on each side; site order and
repeated identical sites are immaterial. No first-site, fuzzy-host or
case-insensitive-account matching transfers a rule. Ambiguous source matches
cannot fall through to fallback. Unmatched items expose their local UUID,
Ask and `needsReview`; R4.7 can present these through `logins()`.
`openAskLogin` refuses Blocked, Automatic and unmatched entries before key use.
The phone remains a follower; owner transfer belongs to R4.5 and cutover.

## Checks performed

- Generic iOS Simulator target built on the physical Mac mini with Xcode beta.
  Its SSH user has no installed simulator runtime, so no simulator run is claimed.
- iPhoneOS target built for Josh's actual paired iPhone with the existing Apple
  Development identity and existing profiles. No certificate or profile changes
  were needed. The app and embedded extensions pass strict code-sign verification.
- CoreDevice's installed-app inventory reports Agent Keyring 0.4.0, build 5.
  Foreground launch was denied because the iPhone is locked. No phone settings changed.
- A disposable storage exercise on the mini invoked the production vault. It
  imported two logins, refreshed one, reopened both, compared the updated password
  and retained password/code seed in memory, and found the other ciphertext
  unchanged. Plaintext fixture secrets were absent from every persisted file.
- The same exercise accepted signed owner indexes, preserved Mac IDs by source
  and by unique fallback, denied Blocked before key agreement, left ambiguous
  Automatic as Ask/review, and rejected changed same-revision bytes and rollback
  after reopening the vault.

The exercise used a software recipient and disposable batches. It establishes
file-storage behavior, not Apple delivery, enclave enforcement or Face ID. No
unit tests or GUI tests ran. Raw build output, installed-app inventory, exercise
source/output and launch failure are under `.private/proofs/r42/` in the main
checkout. The simulator SDK build and exercise ran on the mini without opening
windows on the MacBook.

## Josh's morning check

1. Unlock the iPhone and open **Agent Keyring**. Tap **Allow Exports** if the
   credential provider has not already been enabled.
2. In **Passwords**, select two harmless test logins, then use **… → Export Data
   to Another App → Agent Keyring** and authenticate when Apple asks. If iOS
   offers a different selected-export menu, record its exact wording.
3. Agent Keyring should show **2 logins** in the home-screen footer (or the
   previous count plus these new entries). Close and reopen it: the count stays.
4. Change one test login's password in Passwords. Export **only that login**
   to Agent Keyring. The import date advances and the total stays the same.
   Close and reopen it once more: the total still stays the same.
5. The actual changed password and Face ID gating must be checked through the
   R4.3 approval/opening flow once it is connected. This slice has no new vault
   inspector screen. The count alone does not prove the changed secret opens.

Apple's hand-off, actual enclave creation and Face ID remain device checks.
They are not marked complete by installation or by the disposable exercise.
Cross-device source/fallback/review counts also wait for pairing and a signed
Mac index. All imports remain Ask/review while the phone is unpaired.

## Copy for Opus

After durable save: **“2 logins saved on this iPhone.”** For a selected refresh:
**“Updated from Passwords. Your other logins are kept.”** Before pairing:
**“Pair with your Mac to receive approval requests.”** The existing count/date
state is real; the views should not promise requests or Lock Screen delivery
while `connection == .notPaired`. Add any wording in the designer's lane.

## Diagnostics and next integration

Use subsystem `com.joshpalmer.AgentKeyring.Phone`, categories **Import** and
**Vault**. Stages cover activity/token, Apple transfer, mapped/skipped counts,
public-key loading, enclave keys ready, additive merge totals, sealed/retained
counts, manifest commit, cleanup, and source/fallback/review counts. Errors log
only domain/code chains; no names, sites, tokens, passwords or code seeds.

R4.3 can use `EncryptedPhoneImportDestination.vault` and `.keys` together.
Create one `authenticationContext(reason:)` for an explicit action, pass its
`sharedSecret(with:context:)` into `openAskLogin`, then sign with that same
context. Invalidate it at the action's end. One Face ID across opening and
signing remains an explicit real-device proof. Verify the requested ID, rule,
recipient, lease and signed owner index before opening. No caller should use
`openLocalLogin` to bypass the Ask-only approval path.

Apple references: [Secure Enclave key agreement](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement),
[protected keys](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave),
[restoring an enclave key with an authentication context](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey/init(datarepresentation:authenticationcontext:)).
