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

    @Test("An item absent from a full import is retained for review")
    func fullImportRemoval() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1), item(index: 2)])
        )
        let second = try merger().merge(
            previous: first,
            importBatch: batch(items: [item(index: 2)])
        )

        #expect(second.items.count == 2)
        #expect(second.missingItemIDs == [first.items.first { $0.sourceIdentity == item(index: 1).sourceIdentity }!.id])
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

    @Test("Different source identities stay separate and start on Ask", arguments: ["exporter", "account", "item"])
    func distinctSourceIdentity(component: String) async throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1)])
        )
        let changedSource = item(index: component == "item" ? 99 : 1,
            exporter: component == "exporter" ? "other.exporter" : "com.apple.Passwords",
            account: component == "account" ? "other-account" : "account")
        let second = try merger().merge(
            previous: first,
            importBatch: batch(items: [changedSource])
        )

        #expect(second.items.count == 2)
        #expect(second.items.contains(first.items[0]))
        try await checkRuleAfterImport(first, second, expectedPolicy: .ask)
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

    @Test("Publication needs confirmation for an added login, but not a password-only refresh", arguments: [false, true])
    func publicationAfterRefresh(addLogin: Bool) throws {
        let first = try merger().merge(previous: nil, importBatch: batch(items: [item(index: 1)]))
        var imported = [item(index: 1, password: "refreshed-password")]
        if addLogin { imported.append(item(index: 2)) }
        let second = try merger().merge(previous: first, importBatch: batch(items: imported))
        let rules = [first.items[0].id: CredentialAccessPolicy.allowAutomatically]
        let approver = RelayApprover { throw CocoaError(.fileReadUnknown) }
        var published = try approver.configurationContents(RelayApproverVault(generation: first, policies: rules), machines: [:])
        published.domain = "agentkeyring.configuration.v1"
        published.revision = 12
        published.mirrorRefreshedUnixSeconds = 1_000
        // Use the stored configuration bytes, including after an app upgrade:
        // no old generation-based cache can force a second confirmation.
        let restored = try Agentkeyring_V1_Configuration(serializedBytes: published.serializedData())
        let changed = try approver.publicationDigest(restored)
            != approver.publicationDigest(RelayApproverVault(generation: second, policies: rules), machines: [:])
        #expect(changed == addLogin)
    }

    @Test("Duplicate accounts keep distinct source identities without rejecting the import")
    func ambiguousMatchFails() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1)])
        )
        let ambiguous = batch(items: [item(index: 2), item(index: 3)])

        let second = try merger().merge(previous: first, importBatch: ambiguous)
        #expect(second.items.count == 3)
        #expect(Set(second.items.map(\.sourceIdentity)).count == 3)
        let third = try merger().merge(previous: second, importBatch: ambiguous)
        #expect(Set(third.items.map(\.id)) == Set(second.items.map(\.id)))
        let withOriginal = try merger().merge(previous: first,
            importBatch: batch(items: [item(index: 2), item(index: 1)]))
        #expect(withOriginal.items.count == 2)
        #expect(withOriginal.items.contains { $0.id == first.items[0].id })
    }

    private func merger() -> SnapshotMerger {
        SnapshotMerger(now: { fixedNow })
    }

    private func checkRuleAfterImport(_ first: MirrorGeneration, _ second: MirrorGeneration,
        expectedPolicy: CredentialAccessPolicy) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CredentialAccessPolicyStore(fileURL: root.appendingPathComponent("rules.json"),
            signer: FakeAccessRulesSigner())
        try await confirmInitialAccessRules(in: store, policies: [first.items[0].id: .allowAutomatically])
        let controller = CredentialAccessController(store: store)
        await controller.refresh(from: first)
        #expect(controller.releaseDecision(for: first.items[0].id, field: .password) == .release)
        await controller.refresh(from: second)
        try await controller.ensureRulesConfirmed()
        for item in second.items {
            let expected = item.id == first.items[0].id ? CredentialAccessPolicy.allowAutomatically : expectedPolicy
            #expect(controller.policy(for: item.id) == expected)
            #expect(controller.releaseDecision(for: item.id, field: .password)
                == (expected == .allowAutomatically ? .release : .requestAuthorization))
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
        lastModifiedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> MirrorItem {
        MirrorItem(
            id: UUID(),
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: exporter,
                accountID: Data(account.utf8),
                itemID: Data("item-\(index)".utf8)
            ),
            lastModifiedAt: lastModifiedAt,
            title: "Example",
            origins: origins,
            credentials: [.password(userName: username, password: password)]
        )
    }
}
