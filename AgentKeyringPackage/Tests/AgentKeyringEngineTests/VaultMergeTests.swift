// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// The equal-peer vault: a Mac's and an iPhone's vaults merge to the same
// result in any order, any number of times.

import AgentKeyringApprovalCore
import Foundation
import Testing
@testable import AgentKeyringEngine

@Suite("Equal-peer vault merging")
struct VaultMergeTests {
    private static let created: TimeInterval = 538_768_074.380_438
    private static let modified: TimeInterval = 813_061_445.483_945_4

    /// One device's export of shop.example, as its vault holds it.
    private static func export(by actor: String, at version: UInt64, modified: TimeInterval = modified, title: String = "shop.example") -> CredentialVault {
        let item = exportedItem(site: "shop.example", user: "josh", created: created, modified: modified, title: title).stamped(by: actor, at: version)
        return CredentialVault(items: [item.id: item])
    }

    private static var id: UUID { export(by: "", at: 0).items.keys.first! }

    private static func rule(_ rule: LoginRule, at ms: Int64, by actor: String) -> CredentialVault {
        CredentialVault(rules: [id: LoginRuleTimestampEntry(rule, updatedAtMs: ms, actor: actor)])
    }

    /// Mac and iPhone exports up to 170 ms apart, a real change a minute later,
    /// rule changes on both at once, a Blocked deletion, and a deletion from Passwords.
    private static let vaults: [CredentialVault] = {
        let mac = export(by: "mac", at: 100)
        let iPhone = export(by: "iphone", at: 200, modified: modified + 0.007)
        let iPhoneLater = export(by: "iphone", at: 300, modified: modified + 0.170)
        let changed = export(by: "mac", at: 400, modified: modified + 60, title: "Shop")
        let blocked = CredentialVaultMerge.mergeVaults(mac, rule(.blocked, at: 5_000, by: "iphone")).deletingBlockedSecrets(at: 250)
        let gone = CredentialVault(deleted: [id: Date(timeIntervalSinceReferenceDate: modified + 30)])
        return [mac, iPhone, iPhoneLater, changed, blocked, gone, CredentialVault(),
                rule(.automatic, at: 5_000, by: "mac"), rule(.ask, at: 6_000, by: "mac"), rule(.ask, at: 0, by: "")]
    }()

    @Test("Commutative, associative and idempotent over every combination")
    func laws() {
        for a in Self.vaults {
            #expect(CredentialVaultMerge.mergeVaults(a, a) == a)
            for b in Self.vaults {
                #expect(CredentialVaultMerge.mergeVaults(a, b) == CredentialVaultMerge.mergeVaults(b, a))
                for c in Self.vaults {
                    #expect(CredentialVaultMerge.mergeVaults(CredentialVaultMerge.mergeVaults(a, b), c) == CredentialVaultMerge.mergeVaults(a, CredentialVaultMerge.mergeVaults(b, c)))
                }
            }
        }
    }

    @Test("Passwords' sync jitter between Mac and iPhone is one revision: either export's secret is live, and merging again changes nothing")
    func jitter() throws {
        let mac = Self.export(by: "mac", at: 100)
        let iPhone = Self.export(by: "iphone", at: 200, modified: Self.modified + 0.170)
        let merged = CredentialVaultMerge.mergeVaults(mac, iPhone)
        #expect(merged.items.count == 1)
        #expect(merged.liveSecret(Self.id)?.actor == "iphone")
        #expect(CredentialVaultMerge.mergeVaults(merged, mac) == merged)
        #expect(CredentialVaultMerge.mergeVaults(iPhone, merged) == merged)
        #expect(CredentialVaultMerge.isSameRevision(Date(timeIntervalSinceReferenceDate: 813_061_445.483_945_4),
                                          Date(timeIntervalSinceReferenceDate: 813_061_445.490_945_7)))
    }

    @Test("A change in Passwords wins over the older copy: the older secret is not served for it")
    func newerRevision() {
        let older = Self.export(by: "iphone", at: 500)
        let changed = Self.export(by: "mac", at: 400, modified: Self.modified + 60, title: "Shop")
        let merged = CredentialVaultMerge.mergeVaults(older, changed)
        #expect(merged.items[Self.id]?.title == "Shop")
        #expect(merged.liveSecret(Self.id)?.actor == "mac")
    }

    @Test("Rules set on two devices at once end the same on both: the later wins, then the higher device key")
    func rules() {
        let mac = Self.rule(.automatic, at: 5_000, by: "mac")
        let iPhone = Self.rule(.blocked, at: 5_001, by: "iphone")
        #expect(CredentialVaultMerge.mergeVaults(mac, iPhone).rule(for: Self.id) == .blocked)
        #expect(CredentialVaultMerge.mergeVaults(Self.rule(.ask, at: 5_000, by: "a"), Self.rule(.blocked, at: 5_000, by: "b")).rule(for: Self.id) == .blocked)
        #expect(CredentialVaultMerge.mergeVaults(Self.rule(.blocked, at: 0, by: ""), Self.rule(.ask, at: 1, by: "mac")).rule(for: Self.id) == .ask)
    }

    @Test("Blocked deletes the secret everywhere: a device that missed the block cannot bring it back, even after unblocking; a new export does")
    func blocked() {
        let mac = Self.export(by: "mac", at: 100)
        let staleIPhone = Self.export(by: "iphone", at: 200, modified: Self.modified + 0.007)
        let blocked = CredentialVaultMerge.mergeVaults(mac, Self.rule(.blocked, at: 5_000, by: "mac")).deletingBlockedSecrets(at: 250)
        #expect(blocked.liveSecret(Self.id) == nil)
        #expect(CredentialVaultMerge.mergeVaults(blocked, staleIPhone).liveSecret(Self.id) == nil)

        let unblocked = CredentialVaultMerge.mergeVaults(CredentialVaultMerge.mergeVaults(blocked, staleIPhone), Self.rule(.ask, at: 6_000, by: "iphone"))
        #expect(unblocked.rule(for: Self.id) == .ask)
        #expect(unblocked.liveSecret(Self.id) == nil)
        #expect(unblocked.items[Self.id]?.secretDeleted == true)

        // The Mac exports again; the iPhone's newer-looking (jittered) entry does not hide it.
        let restored = CredentialVaultMerge.mergeVaults(unblocked, Self.export(by: "mac", at: 700))
        #expect(restored.liveSecret(Self.id)?.version == 700)
        #expect(restored.items[Self.id]?.secretDeleted == false)
    }

    @Test("A login gone from Passwords stays gone when an older vault arrives; changed or exported since, it is back")
    func deletion() {
        let goneAt = Date(timeIntervalSinceReferenceDate: Self.modified + 30)
        let gone = CredentialVault(deleted: [Self.id: goneAt])
        #expect(!CredentialVaultMerge.mergeVaults(Self.export(by: "iphone", at: 200), gone).isLive(Self.id))
        #expect(CredentialVaultMerge.mergeVaults(Self.export(by: "mac", at: 400, modified: Self.modified + 60), gone).isLive(Self.id))
        let exportedSince = UInt64((goneAt.timeIntervalSince1970 + 1) * 1_000_000_000)
        #expect(CredentialVaultMerge.mergeVaults(Self.export(by: "iphone", at: exportedSince), gone).isLive(Self.id))
    }

    @Test("A rule from another device's catalogue: only what it changed from the catalogue it started from counts, and the later stays")
    func receivedRules() {
        let local = LoginRuleTimestampEntry(.blocked, updatedAtMs: 5_000, actor: "mac")
        func received(_ rule: LoginRule, _ ms: Int64, _ actor: String, base: LoginRuleTimestampEntry? = local, local: LoginRuleTimestampEntry? = local) -> LoginRuleTimestampEntry? {
            LoginRuleTimestampEntry.received(LoginRuleTimestampEntry(rule, updatedAtMs: ms, actor: actor), base: base, local: local)
        }
        // Another device's edit, newer or older than this Mac's.
        #expect(received(.ask, 6_000, "iphone") == LoginRuleTimestampEntry(.ask, updatedAtMs: 6_000, actor: "iphone"))
        #expect(received(.ask, 4_000, "iphone") == local)
        // Unchanged from the catalogue it started from: no edit, even of a rule changed here since.
        let newerHere = LoginRuleTimestampEntry(.ask, updatedAtMs: 8_000, actor: "mac")
        #expect(received(.blocked, 5_000, "mac", local: newerHere) == newerHere)
        // A login it never set a rule for (an import) never undoes one set here.
        #expect(received(.ask, 0, "", base: nil) == local)
        #expect(received(.ask, 0, "", base: nil, local: nil) == LoginRuleTimestampEntry(.ask, updatedAtMs: 0, actor: ""))
        // Set at the same moment: Block stays, whichever device's key sorts higher.
        #expect(received(.automatic, 5_000, "zz-iphone") == local)
        #expect(LoginRuleTimestampEntry.latest(LoginRuleTimestampEntry(.ask, updatedAtMs: 5_000, actor: "zz"), LoginRuleTimestampEntry(.blocked, updatedAtMs: 5_000, actor: "aa"))?.rule == .blocked)
    }

    @Test("A rule set here is later than the one it replaces, even with this device's clock behind")
    func monotonic() {
        let local = LoginRuleTimestampEntry(.blocked, updatedAtMs: 5_000, actor: "iphone")
        #expect(LoginRuleTimestampEntry.set(.ask, replacing: local, at: 1_000, by: "mac").updatedAtMs == 5_001)
        #expect(LoginRuleTimestampEntry.set(.ask, replacing: local, at: 9_000, by: "mac").updatedAtMs == 9_000)
        #expect(LoginRuleTimestampEntry.latest(local, LoginRuleTimestampEntry.set(.ask, replacing: local, at: 1_000, by: "a"))?.rule == .ask)
    }

    @Test("An older export imported late rolls nothing back: no deleted login returns, and no older secret replaces a newer one")
    func lateExports() {
        let goneAt = Date(timeIntervalSinceReferenceDate: Self.modified + 30)
        func stamped(_ modified: TimeInterval, version: UInt64, exportedAt: Date, title: String = "shop.example") -> CredentialVault {
            let plain = exportedItem(site: "shop.example", user: "josh", created: Self.created, modified: modified, title: title)
            let item = StoredVaultLogin(id: Self.id, sourceIdentity: plain.sourceIdentity, createdAt: plain.createdAt, lastModifiedAt: plain.lastModifiedAt,
                title: plain.title, origins: plain.origins, credentials: plain.redacted.credentials,
                imports: [LoginSecretRevisionStamp(revision: plain.lastModifiedAt, version: version, actor: "mac", exportedAt: exportedAt)])
            return CredentialVault(items: [Self.id: item])
        }
        // Exported before the export that found it gone, imported after: still gone.
        let late = stamped(Self.modified, version: 9_000, exportedAt: goneAt.addingTimeInterval(-10))
        #expect(!CredentialVaultMerge.mergeVaults(late, CredentialVault(deleted: [Self.id: goneAt])).isLive(Self.id))
        #expect(CredentialVaultMerge.mergeVaults(stamped(Self.modified, version: 9_000, exportedAt: goneAt.addingTimeInterval(10)),
                                 CredentialVault(deleted: [Self.id: goneAt])).isLive(Self.id))

        // A change a minute later is held; the older revision imported afterwards does not displace its secret.
        let newer = stamped(Self.modified + 60, version: 1_000, exportedAt: goneAt, title: "Shop")
        let older = stamped(Self.modified, version: 2_000, exportedAt: goneAt.addingTimeInterval(-60))
        #expect(CredentialVaultMerge.mergeVaults(newer, older).liveSecret(Self.id)?.version == 1_000)
        #expect(CredentialVaultMerge.mergeVaults(newer, older).items[Self.id]?.title == "Shop")

        // A change a second later, inside the window: the older revision imported afterwards does not win either.
        let second = stamped(Self.modified + 1, version: 1_000, exportedAt: goneAt, title: "Shop")
        #expect(CredentialVaultMerge.mergeVaults(second, older).liveSecret(Self.id)?.version == 1_000)
        #expect(CredentialVaultMerge.mergeVaults(older, second).liveSecret(Self.id)?.version == 1_000)
    }
}
