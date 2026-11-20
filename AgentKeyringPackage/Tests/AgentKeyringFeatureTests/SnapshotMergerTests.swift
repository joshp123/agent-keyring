import Foundation
import Testing
import AgentKeyringTestSupport
import AgentKeyringProtocol
@testable import AgentKeyringFeature

@MainActor
@Suite("Snapshot merging")
struct SnapshotMergerTests {
    private let fixedNow = Date(timeIntervalSince1970: 2_000)

    @Test("Initial full import contains every exported item")
    func initialFullImport() throws {
        let generation = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1), item(index: 2)])
        )

        #expect(generation.items.count == 2)
    }

    @Test("Copying the same passwords again keeps one entry each, with its id, so his rules stay; a doubled list goes back to one of each")
    func copyingAgain() throws {
        // As the Passwords app exports: every export gives every item a new account and item id.
        func export(_ number: Int) -> [MirrorItem] {
            [item(index: 1, origins: ["https://mail.example"], account: "export-\(number)", createdAt: 1),
             item(index: 2, origins: ["https://shop.example"], account: "export-\(number)", createdAt: 2),
             // Two entries the Passwords app holds with the same site, account and title.
             item(index: 3, origins: ["https://bank.example"], account: "export-\(number)", createdAt: 3),
             item(index: 4, origins: ["https://bank.example"], account: "export-\(number)", createdAt: 4)]
        }
        let first = try merger().merge(previous: nil, importBatch: batch(items: export(1)))
        let second = try merger().merge(previous: first, importBatch: batch(items: export(2)))
        #expect(second.items.count == 4)
        #expect(Set(second.items.map(\.id)) == Set(first.items.map(\.id)))
        #expect(second.items.first { $0.createdAt == Date(timeIntervalSince1970: 4) }?.id
            == first.items.first { $0.createdAt == Date(timeIntervalSince1970: 4) }?.id)

        // The list an earlier build doubled: each entry twice. The copy with his rule on it is kept.
        let doubled = MirrorGeneration(id: UUID(), previousGenerationID: nil, createdAt: fixedNow, sourceExportedAt: fixedNow,
            scope: .full, exporterIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords",
            items: first.items + second.items.map { MirrorItem(id: UUID(), sourceIdentity: $0.sourceIdentity, createdAt: $0.createdAt,
                lastModifiedAt: $0.lastModifiedAt, title: $0.title, origins: $0.origins, credentials: $0.credentials) },
            skippedCredentialCount: 0)
        let ruled = Set(first.items.map { $0.id })
        let third = try merger().merge(previous: doubled, importBatch: batch(items: export(3)), keep: ruled)
        #expect(third.items.count == 4)
        #expect(Set(third.items.map(\.id)) == ruled)
    }

    @Test("A changed password replaces the previous value even when its timestamp is unchanged")
    func passwordChangeWithUnchangedTimestamp() async throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1, password: "before")])
        )
        let second = try merger().merge(
            previous: first,
            importBatch: batch(items: [item(index: 1, password: "after")])
        )

        #expect(second.items.first?.credentials == [.password(userName: "agent@example.com", password: "after")])
        #expect(second.items.first?.id == first.items.first?.id)
        try await checkRuleAfterImport(first, second, expectedPolicy: .allowAutomatically)
    }

    @Test("Case-distinct account names on the same Apple item cannot inherit Automatic")
    func changedAccount() async throws {
        let first = try merger().merge(previous: nil,
            importBatch: batch(items: [item(index: 1, username: "CaseSensitive")]))
        let second = try merger().merge(previous: first,
            importBatch: batch(items: [item(index: 1, username: "casesensitive")]))
        #expect(second.items.count == 1)
        #expect(second.items[0].id != first.items[0].id)
        try await checkRuleAfterImport(first, second, expectedPolicy: .ask)
    }

    @Test("Swapping password and code account names cannot inherit Automatic")
    func changedCredentialAccounts() async throws {
        func login(passwordAccount: String, codeAccount: String) -> MirrorItem {
            let source = item(index: 1)
            return MirrorItem(id: source.id, sourceIdentity: source.sourceIdentity, title: source.title,
                origins: source.origins, credentials: [.password(userName: passwordAccount, password: "synthetic"),
                    .totp(secret: Data("synthetic-seed".utf8), period: 30, digits: 6,
                        userName: codeAccount, algorithm: .sha1, issuer: nil)])
        }
        let first = try merger().merge(previous: nil,
            importBatch: batch(items: [login(passwordAccount: "first-account", codeAccount: "second-account")]))
        let second = try merger().merge(previous: first,
            importBatch: batch(items: [login(passwordAccount: "second-account", codeAccount: "first-account")]))
        #expect(second.items[0].id != first.items[0].id)
        try await checkRuleAfterImport(first, second, expectedPolicy: .ask)
    }

    @Test("Changing a secondary destination on the same Apple item cannot inherit Automatic")
    func changedSecondaryDestination() async throws {
        let first = try merger().merge(previous: nil, importBatch: batch(items: [item(index: 1,
            origins: ["https://example.com", "https://z.example.com"])]))
        let second = try merger().merge(previous: first, importBatch: batch(items: [item(index: 1,
            origins: ["https://example.com", "https://other.example.net"])]))
        #expect(second.items.count == 1)
        #expect(second.items[0].id != first.items[0].id)
        try await checkRuleAfterImport(first, second, expectedPolicy: .ask)
    }

    @Test("Reordering the same destinations during a password refresh keeps Automatic")
    func reorderedDestinations() async throws {
        let first = try merger().merge(previous: nil, importBatch: batch(items: [item(index: 1,
            origins: ["https://example.com", "https://z.example.com"])]))
        let second = try merger().merge(previous: first, importBatch: batch(items: [item(index: 1,
            password: "new-password", origins: ["https://z.example.com", "https://example.com"])]))
        #expect(second.items[0].id == first.items[0].id)
        try await checkRuleAfterImport(first, second, expectedPolicy: .allowAutomatically)
    }

    private func merger() -> SnapshotMerger {
        SnapshotMerger(now: { fixedNow })
    }

    private func checkRuleAfterImport(_ first: MirrorGeneration, _ second: MirrorGeneration,
        expectedPolicy: CredentialAccessPolicy) async throws {
        var saved: Data?
        let store = CredentialAccessPolicyStore(read: { saved }, write: { saved = $0 })
        try store.save([first.items[0].id: .allowAutomatically])
        let controller = CredentialAccessController(store: store)
        await controller.refresh(from: second)
        for item in second.items {
            let expected = item.id == first.items[0].id ? CredentialAccessPolicy.allowAutomatically : expectedPolicy
            #expect(controller.policy(for: item.id) == expected)
        }
    }

    private func batch(items: [MirrorItem]) -> MirrorImportBatch {
        MirrorImportBatch(
            scope: .full,
            exportedAt: fixedNow,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: items,
            skippedCredentialCount: 0
        )
    }

    private func item(
        index: Int,
        password: String = "secret",
        username: String = "agent@example.com",
        origins: [String] = ["https://example.com/login"],
        exporter: String = "com.apple.Passwords",
        account: String = "account",
        lastModifiedAt: Date = Date(timeIntervalSince1970: 100),
        createdAt: TimeInterval? = nil
    ) -> MirrorItem {
        MirrorItem(
            id: UUID(),
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: exporter,
                accountID: Data(account.utf8),
                itemID: Data("item-\(index)".utf8)
            ),
            createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
            lastModifiedAt: lastModifiedAt,
            title: "Example",
            origins: origins,
            credentials: [.password(userName: username, password: password)]
        )
    }
}
