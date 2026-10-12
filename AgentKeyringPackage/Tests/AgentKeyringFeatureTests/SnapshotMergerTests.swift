import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Snapshot merging")
struct SnapshotMergerTests {
    private let fixedNow = Date(timeIntervalSince1970: 2_000)

    @Test("Initial full import reports every item as added")
    func initialFullImport() throws {
        let generation = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1), item(index: 2)])
        )

        #expect(generation.items.count == 2)
        #expect(generation.delta.addedItemIDs.count == 2)
        #expect(generation.delta.changedItems.isEmpty)
        #expect(generation.delta.removedItemIDs.isEmpty)
    }

    @Test("An item absent from the next full import is removed")
    func fullImportRemoval() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1), item(index: 2)])
        )
        let second = try merger().merge(
            previous: first,
            importBatch: batch(items: [item(index: 2)])
        )

        #expect(second.items.count == 1)
        #expect(second.delta.removedItemIDs.count == 1)
    }

    @Test("A changed password is detected even when its timestamp is unchanged")
    func passwordChangeWithUnchangedTimestamp() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1, password: "before")])
        )
        let second = try merger().merge(
            previous: first,
            importBatch: batch(items: [item(index: 1, password: "after")])
        )

        #expect(second.delta.changedItems.count == 1)
        #expect(second.delta.changedItems.first?.credentialsChanged == true)
    }

    @Test("A newer source timestamp alone does not report a credential change")
    func timestampOnlyChange() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [
                item(index: 1, lastModifiedAt: Date(timeIntervalSince1970: 100))
            ])
        )
        let second = try merger().merge(
            previous: first,
            importBatch: batch(items: [
                item(index: 1, lastModifiedAt: Date(timeIntervalSince1970: 200))
            ])
        )

        #expect(second.delta.changedItems.isEmpty)
    }

    @Test("A selected import preserves items outside the selection")
    func selectedImportIsIsolated() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1), item(index: 2)])
        )
        let selected = MirrorImportBatch(
            scope: .selected,
            exportedAt: fixedNow,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: [item(index: 1, password: "updated")],
            skippedCredentialCount: 0
        )
        let second = try merger().merge(previous: first, importBatch: selected)

        #expect(second.items.count == 2)
        #expect(second.delta.changedItems.count == 1)
        #expect(second.delta.removedItemIDs.isEmpty)
    }

    @Test("A unique natural key preserves identity when a source ID changes")
    func naturalKeyFallback() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1)])
        )
        let changedSource = item(index: 99)
        let second = try merger().merge(
            previous: first,
            importBatch: batch(items: [changedSource])
        )

        #expect(second.items.first?.id == first.items.first?.id)
        #expect(second.delta.addedItemIDs.isEmpty)
        #expect(second.delta.removedItemIDs.isEmpty)
    }

    @Test("Duplicate accounts keep distinct source identities without rejecting the import")
    func ambiguousMatchFails() throws {
        let first = try merger().merge(
            previous: nil,
            importBatch: batch(items: [item(index: 1)])
        )
        let ambiguous = batch(items: [item(index: 2), item(index: 3)])

        let second = try merger().merge(previous: first, importBatch: ambiguous)
        #expect(second.items.count == 2)
        #expect(Set(second.items.map(\.sourceIdentity)).count == 2)
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
        lastModifiedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> MirrorItem {
        MirrorItem(
            id: UUID(),
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: "com.apple.Passwords",
                accountID: Data("account".utf8),
                itemID: Data("item-\(index)".utf8)
            ),
            lastModifiedAt: lastModifiedAt,
            title: "Example",
            origins: ["https://example.com/login"],
            credentials: [.password(userName: "agent@example.com", password: password)]
        )
    }
}
