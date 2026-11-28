// Rewritten by AI on 2026.11.23 by model claude opus 5.5, for IDs worked out
// from each login (LoginIdentity) and the equal-peer vault (CredentialVaultMerge.swift).

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import Foundation
import Testing
@testable import AgentKeyringEngine

/// As Passwords exports: new random item and account IDs every time, the same creation time to the microsecond.
func exportedItem(site: String, user: String, created: TimeInterval?, modified: TimeInterval = 813_061_445.483_945_4,
                  password: String = "secret", origins: [String]? = nil, title: String? = nil) -> StoredVaultLogin {
    StoredVaultLogin(id: UUID(), sourceIdentity: LoginSourceIdentity(exporterIdentifier: "com.apple.Passwords",
            accountID: Data(UUID().uuidString.utf8), itemID: Data(UUID().uuidString.utf8)),
        createdAt: created.map(Date.init(timeIntervalSinceReferenceDate:)), lastModifiedAt: Date(timeIntervalSinceReferenceDate: modified),
        title: title ?? site, origins: origins ?? ["https://\(site)/login"], credentials: [.password(userName: user, password: password)])
}

extension StoredVaultLogin {
    /// This login as a device's vault holds it after exporting it: its ID, its import, no secret.
    func stamped(by actor: String, at version: UInt64) -> StoredVaultLogin {
        StoredVaultLogin(id: LoginIdentity.ids(for: [self])[0], sourceIdentity: sourceIdentity, createdAt: createdAt, lastModifiedAt: lastModifiedAt,
            title: title, subtitle: subtitle, isFavorite: isFavorite, origins: origins, credentials: redacted.credentials,
            imports: [LoginSecretRevisionStamp(revision: lastModifiedAt, version: version, actor: actor)])
    }
}

/// Exported after the tests' merger imports, as every export after the first is.
func exportBatch(_ items: [StoredVaultLogin], scope: LoginImportScope = .full, at date: Date = Date(timeIntervalSince1970: 2_000_000_200)) -> LoginImportBatch {
    LoginImportBatch(scope: scope, exportedAt: date, exporterIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords",
        items: items, skippedCredentialCount: 0)
}

@Suite("Login IDs")
struct LoginIdentityTests {
    @Test("The ID is fixed for ever: SHA-256 of site, account and creation time, shaped as a version 5 UUID")
    func golden() {
        let item = exportedItem(site: "github.com", user: "Josh@Example.com ", created: 538_768_074.380_438,
            origins: ["https://www.GitHub.com/login", "https://zz.github.com"])
        #expect(LoginIdentity.key(item) == "ak-login-v1:github.com\u{0}josh@example.com\u{0}538768074380438")
        #expect(LoginIdentity.ids(for: [item]) == [UUID(uuidString: "65D2D12E-C596-57EB-98F5-8497274F93EA")!])
        #expect(LoginIdentity.ids(for: [StoredVaultLogin.testPassword]).map(\.uuidString) == ["BE22E917-B08D-5D0C-BD65-16A04D230625"])
    }

    @Test("A Mac export and an iPhone export of the same logins give the same IDs; two github.com logins for one account stay two")
    func macAndIPhone() throws {
        func export(jitter: TimeInterval) -> [StoredVaultLogin] {
            [exportedItem(site: "github.com", user: "josh", created: 538_768_074.380_438, modified: 813_061_445.483_945_4 + jitter),
             exportedItem(site: "github.com", user: "josh", created: 626_706_465.394_669, modified: 813_061_445.483_945_4 + jitter),
             exportedItem(site: "bank.example", user: "josh", created: 700_000_000.1, modified: 813_000_000 + jitter)]
        }
        let mac = export(jitter: 0)
        let iPhone = Array(export(jitter: 0.007).reversed())
        let macIDs = LoginIdentity.ids(for: mac)
        #expect(Set(macIDs).count == 3)
        #expect(Set(LoginIdentity.ids(for: iPhone)) == Set(macIDs))
        #expect(LoginIdentity.ids(for: iPhone).reversed() == macIDs)

        // The saved list has no secrets: the IDs are the same from it.
        let saved = try mac.map { item in
            let data = try item.redacted.storedProto().serializedData()
            return try StoredVaultLogin(storedProto: Agentkeyring_V2_StoredVaultLogin(serializedBytes: data))
        }
        #expect(LoginIdentity.ids(for: saved) == macIDs)
    }

    @Test("Two logins for one account made a millisecond apart are two, by their creation time alone")
    func microseconds() {
        let a = exportedItem(site: "github.com", user: "josh", created: 538_768_074.380_438)
        let b = exportedItem(site: "github.com", user: "josh", created: 538_768_074.380_201)
        let ids = LoginIdentity.ids(for: [a, b])
        #expect(ids[0] != ids[1])
        #expect(ids == LoginIdentity.ids(for: [a]) + LoginIdentity.ids(for: [b]))
    }

    @Test("One login an export lists twice is kept once, the newer copy, in either order")
    func listedTwice() throws {
        let older = exportedItem(site: "router.local", user: "admin", created: 1, modified: 1, password: "old")
        let newer = exportedItem(site: "router.local", user: "admin", created: 1, modified: 2, password: "new")
        #expect(LoginIdentity.ids(for: [older]) == LoginIdentity.ids(for: [newer]))
        for items in [[older, newer], [newer, older]] {
            let merged = try VaultSnapshotMerger().mergeImportedSnapshot(previous: nil, importBatch: exportBatch(items), actor: "mac")
            #expect(merged.snapshot.items.map(\.credentials) == [[.password(userName: "admin", password: "new")]])
        }
    }

    @Test("Two logins made by hand with one site, account name and title keep both passwords, in either order")
    func undatedTwinsStayTwo() throws {
        let first = exportedItem(site: "router.local", user: "admin", created: nil, modified: 1, password: "upstairs")
        let second = exportedItem(site: "router.local", user: "admin", created: nil, modified: 1, password: "downstairs")
        #expect(LoginIdentity.ids(for: [first]) == LoginIdentity.ids(for: [second]))
        for items in [[first, second], [second, first]] {
            let ids = LoginIdentity.ids(for: items)
            #expect(Set(ids).count == 2)
            #expect(ids.contains(LoginIdentity.ids(for: [first])[0]))
            let merged = try VaultSnapshotMerger().mergeImportedSnapshot(previous: nil, importBatch: exportBatch(items), actor: "mac")
            let passwords = merged.snapshot.items.flatMap(\.credentials).compactMap { secret -> String? in
                if case let .password(_, password) = secret { return password } else { return nil }
            }
            #expect(passwords.sorted() == ["downstairs", "upstairs"])
        }
    }
}

@MainActor
@Suite("Snapshot merging")
struct SnapshotMergerTests {
    private let merger = VaultSnapshotMerger(now: { Date(timeIntervalSince1970: 2_000_000_100) })
    private let mac = "mac-key"

    @Test("Copying again keeps every ID, a changed password included")
    func copyingAgain() throws {
        let first = try merger.mergeImportedSnapshot(previous: nil, importBatch: exportBatch([exportedItem(site: "shop.example", user: "josh", created: 1, password: "before")]), actor: mac)
        let second = try merger.mergeImportedSnapshot(previous: first.snapshot.redacted,
            importBatch: exportBatch([exportedItem(site: "shop.example", user: "josh", created: 1, password: "after")]), actor: mac)
        #expect(second.snapshot.items.map(\.id) == first.snapshot.items.map(\.id))
        #expect(second.snapshot.items[0].credentials == [.password(userName: "josh", password: "after")])
    }

    @Test("Changed account names or sites keep the ID but lose Automatic; Blocked stays Blocked; reordered sites keep Automatic",
          arguments: [("Josh", ["https://shop.example/login", "https://z.shop.example"], LoginRule.ask),
                      ("josh", ["https://shop.example/login", "https://x.other.example"], .ask),
                      ("josh", ["https://z.shop.example", "https://shop.example/login"], .automatic)])
    func authorisationChanges(user: String, origins: [String], expected: LoginRule) throws {
        let before = try merger.mergeImportedSnapshot(previous: nil, importBatch: exportBatch([exportedItem(site: "shop.example", user: "josh", created: 1,
            origins: ["https://shop.example/login", "https://z.shop.example"])]), actor: mac)
        let id = before.snapshot.items[0].id
        for (rule, wanted) in [(LoginRule.automatic, expected), (.blocked, .blocked)] {
            let after = try merger.mergeImportedSnapshot(previous: before.snapshot.redacted,
                importBatch: exportBatch([exportedItem(site: "shop.example", user: user, created: 1, origins: origins)]),
                rules: [id: LoginRuleTimestampEntry(rule, updatedAtMs: 5, actor: mac)], actor: mac)
            #expect(after.snapshot.items.map(\.id) == [id])
            #expect(after.rules[id]?.rule == wanted)
        }
    }

    @Test("A new lowest site or another account name makes it another login, which starts at Ask")
    func newIdentity() throws {
        let before = try merger.mergeImportedSnapshot(previous: nil, importBatch: exportBatch([exportedItem(site: "shop.example", user: "josh", created: 1)]), actor: mac)
        let id = before.snapshot.items[0].id
        let after = try merger.mergeImportedSnapshot(previous: before.snapshot.redacted,
            importBatch: exportBatch([exportedItem(site: "shop.example", user: "josh", created: 1, origins: ["https://shop.example/login", "https://a.example"])]),
            rules: [id: LoginRuleTimestampEntry(.blocked, updatedAtMs: 5, actor: mac)], actor: mac)
        #expect(after.snapshot.items.map(\.id) != [id])
        #expect(after.snapshot.missingItemIDs == [id])
        #expect(after.rules[after.snapshot.items[0].id] == nil)
    }

    @Test("Exporting 1-2 selected logins, then exporting more later keeps earlier logins and rules, and updates re-exported ones")
    func selectedExportsMergeAdditively() throws {
        let github = exportedItem(site: "github.com", user: "josh", created: 1, modified: 100, password: "v1")
        let resend = exportedItem(site: "resend.com", user: "josh", created: 2, modified: 100, password: "r1")
        let linear = exportedItem(site: "linear.app", user: "josh", created: 3, modified: 100, password: "l1")

        let first = try merger.mergeImportedSnapshot(previous: nil, importBatch: exportBatch([github], scope: .selected), actor: mac, version: 1)
        let githubID = first.snapshot.items[0].id
        let rules = [githubID: LoginRuleTimestampEntry(.automatic, updatedAtMs: 5, actor: mac)]

        let second = try merger.mergeImportedSnapshot(previous: first.snapshot.redacted,
            importBatch: exportBatch([resend, linear], scope: .selected), rules: rules, actor: mac, version: 2)
        #expect(Set(second.snapshot.items.map(\.title)) == ["github.com", "resend.com", "linear.app"])
        #expect(second.snapshot.missingItemIDs == [])
        #expect(second.snapshot.deleted == nil)
        #expect(second.rules[githubID]?.rule == .automatic)
        #expect(!second.sealing.contains(githubID))
        #expect(second.sealing.count == 2)

        let githubUpdated = exportedItem(site: "github.com", user: "josh", created: 1, modified: 200, password: "v2")
        let third = try merger.mergeImportedSnapshot(previous: second.snapshot.redacted,
            importBatch: exportBatch([githubUpdated], scope: .selected), rules: second.rules, actor: mac, version: 3)
        #expect(Set(third.snapshot.items.map(\.title)) == ["github.com", "resend.com", "linear.app"])
        #expect(third.sealing == [githubID])
        #expect(third.snapshot.items.first { $0.id == githubID }?.credentials == [.password(userName: "josh", password: "v2")])
        #expect(third.rules[githubID]?.rule == .automatic)
    }

    @Test("A full copy finds the passwords gone from Passwords; a password from another device it never exported stays")
    func deletions() throws {
        let shop = exportedItem(site: "shop.example", user: "josh", created: 1)
        let mail = exportedItem(site: "mail.example", user: "josh", created: 2)
        let first = try merger.mergeImportedSnapshot(previous: nil, importBatch: exportBatch([shop, mail]), actor: mac)
        var fromIPhone = first.snapshot.redacted
        fromIPhone = StoredVaultSnapshot(id: UUID(), previousSnapshotID: nil, createdAt: .now, sourceExportedAt: .now, scope: .full,
            exporterIdentifier: "", exporterDisplayName: "", items: fromIPhone.items
                + [exportedItem(site: "forum.example", user: "josh", created: 3).stamped(by: "iphone-key", at: 1)],
            skippedCredentialCount: 0)

        let second = try merger.mergeImportedSnapshot(previous: fromIPhone, importBatch: exportBatch([exportedItem(site: "shop.example", user: "josh", created: 1)]), actor: mac)
        let titles = Set(second.snapshot.items.map(\.title))
        #expect(titles == ["shop.example", "forum.example"])
        #expect(second.snapshot.missingItemIDs == LoginIdentity.ids(for: [mail]))
        #expect(second.snapshot.deleted?.keys.sorted { $0.uuidString < $1.uuidString } == LoginIdentity.ids(for: [mail]))
    }

    @Test("A password missing from one full copy and back in the next, unchanged, is live and sealed again")
    func backAgain() throws {
        let shop = { exportedItem(site: "shop.example", user: "josh", created: 1) }
        let mail = { exportedItem(site: "mail.example", user: "josh", created: 2) }
        let first = try merger.mergeImportedSnapshot(previous: nil, importBatch: exportBatch([shop(), mail()], at: Date(timeIntervalSince1970: 1_900_000_000)),
            actor: mac, version: 1_900_000_001_000_000_000)
        let missing = try merger.mergeImportedSnapshot(previous: first.snapshot.redacted, importBatch: exportBatch([shop()], at: Date(timeIntervalSince1970: 1_900_000_100)),
            actor: mac, version: 1_900_000_101_000_000_000)
        let id = LoginIdentity.ids(for: [mail()])[0]
        #expect(!missing.snapshot.items.contains { $0.id == id })
        let back = try merger.mergeImportedSnapshot(previous: missing.snapshot.redacted, importBatch: exportBatch([shop(), mail()], at: Date(timeIntervalSince1970: 1_900_000_200)),
            actor: mac, version: 1_900_000_201_000_000_000)
        #expect(back.snapshot.items.contains { $0.id == id })
        #expect(back.sealing.contains(id))
    }

    @Test("A Blocked password in a new copy is not kept; unblocked, the next copy brings it back")
    func blockedThenUnblocked() throws {
        let shop = { exportedItem(site: "shop.example", user: "josh", created: 1) }
        let first = try merger.mergeImportedSnapshot(previous: nil, importBatch: exportBatch([shop()]), actor: mac, version: 1)
        let id = first.snapshot.items[0].id
        let blocked = [id: LoginRuleTimestampEntry(.blocked, updatedAtMs: 10, actor: mac)]
        let deleted = first.snapshot.redacted.deletingSecrets(of: [id], at: 2)
        #expect(deleted.items.first { $0.id == id }?.secretDeleted == true)

        let reexported = try merger.mergeImportedSnapshot(previous: deleted, importBatch: exportBatch([shop()]), rules: blocked, actor: mac, version: 3)
        #expect(!reexported.sealing.contains(id))
        #expect(reexported.snapshot.items.first { $0.id == id }?.secretDeleted == true)
        #expect(reexported.snapshot.items.first { $0.id == id }?.credentials == [.password(userName: "josh", password: "")])

        let unblocked = [id: LoginRuleTimestampEntry(.ask, updatedAtMs: 20, actor: mac)]
        let stillDeleted = try merger.mergeImportedSnapshot(previous: reexported.snapshot.redacted, importBatch: exportBatch([], scope: .unknown), rules: unblocked,
            actor: mac, version: 4)
        #expect(stillDeleted.snapshot.items.first { $0.id == id }?.secretDeleted == true)
        let restored = try merger.mergeImportedSnapshot(previous: stillDeleted.snapshot.redacted, importBatch: exportBatch([shop()]), rules: unblocked,
            actor: mac, version: 5)
        #expect(restored.sealing.contains(id))
        #expect(restored.snapshot.items.first { $0.id == id }?.secretDeleted == false)
    }
}
