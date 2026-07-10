import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Credential access policies")
struct CredentialAccessPolicyTests {
    @MainActor
    @Test("New credentials ask, automatic access skips approval, and blocked access fails closed")
    func releaseDecisions() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let controller = CredentialAccessController(store: fixture.store)
        let generation = fixture.generation()
        let credentialID = generation.items[0].id

        await controller.refresh(from: generation)
        #expect(
            controller.releaseDecision(for: credentialID, field: .password) == .requestAuthorization
        )
        #expect(controller.releaseDecision(for: credentialID, field: .username) == .release)

        await controller.setPolicy(.allowAutomatically, for: [credentialID])
        #expect(controller.releaseDecision(for: credentialID, field: .password) == .release)

        await controller.setPolicy(.block, for: [credentialID])
        #expect(controller.releaseDecision(for: credentialID, field: .username) == .block)
        #expect(controller.releaseDecision(for: credentialID, field: .password) == .block)
    }

    @MainActor
    @Test("Rules persist by stable credential ID and survive a refreshed generation")
    func persistenceAcrossRefresh() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = fixture.generation()
        let credentialID = first.items[0].id
        let controller = CredentialAccessController(store: fixture.store)

        await controller.refresh(from: first)
        await controller.setPolicy(.allowAutomatically, for: [credentialID])

        let reloaded = CredentialAccessController(store: fixture.store)
        await reloaded.refresh(from: fixture.generation(id: UUID(), credentialID: credentialID))

        #expect(reloaded.policy(for: credentialID) == .allowAutomatically)
        #expect(reloaded.rows.first?.id == credentialID)
    }

    @MainActor
    @Test("Search is case-insensitive, diacritic-insensitive and fuzzy")
    func fuzzySearch() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let controller = CredentialAccessController(store: fixture.store)
        await controller.refresh(from: fixture.generation(title: "Café Account"))

        controller.searchText = "cafe"
        #expect(controller.visibleRows.count == 1)

        controller.searchText = "cfacc"
        #expect(controller.visibleRows.count == 1)

        controller.searchText = "unrelated"
        #expect(controller.visibleRows.isEmpty)
    }

    @MainActor
    @Test("Bulk recommendations update groups in one saved policy set")
    func bulkRecommendations() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let controller = CredentialAccessController(store: fixture.store)
        let first = fixture.generation()
        let firstID = first.items[0].id
        await controller.refresh(from: first)

        await controller.setPolicies([firstID: .block])

        #expect(controller.count(for: .ask) == 0)
        #expect(controller.count(for: .block) == 1)
        #expect(controller.visibleRows.isEmpty)

        controller.selectedPolicy = .block
        #expect(controller.visibleRows.map(\.id) == [firstID])
    }

    @Test("The policy file contains no credential metadata and is owner-only")
    func securePolicyFile() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let credentialID = UUID()

        try await fixture.store.save([credentialID: .block])

        let data = try Data(contentsOf: fixture.fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(text.contains(credentialID.uuidString))
        #expect(!text.contains("example.com"))
        #expect(permissions?.intValue == 0o600)
    }

    @Test("A duplicated policy record is rejected as corrupt")
    func duplicateRecord() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directoryURL,
            withIntermediateDirectories: true
        )
        let credentialID = UUID()
        let json = """
            {"version":1,"records":[
              {"credentialID":"\(credentialID.uuidString)","policy":"block"},
              {"credentialID":"\(credentialID.uuidString)","policy":"allowAutomatically"}
            ]}
            """
        try Data(json.utf8).write(to: fixture.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.fileURL.path
        )

        await #expect(throws: CocoaError.self) {
            try await fixture.store.load()
        }
    }
}

private struct Fixture {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentKeyringPolicyTests-\(UUID().uuidString)", isDirectory: true)

    var fileURL: URL {
        directoryURL.appendingPathComponent("access-policies.json")
    }

    var store: CredentialAccessPolicyStore {
        CredentialAccessPolicyStore(fileURL: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func generation(
        id: UUID = UUID(),
        credentialID: UUID = UUID(),
        title: String = "Example"
    ) -> MirrorGeneration {
        MirrorGeneration(
            id: id,
            previousGenerationID: nil,
            createdAt: Date(timeIntervalSince1970: 2_000),
            sourceExportedAt: Date(timeIntervalSince1970: 1_900),
            scope: .full,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: [
                MirrorItem(
                    id: credentialID,
                    sourceIdentity: MirrorSourceIdentity(
                        exporterIdentifier: "com.apple.Passwords",
                        accountID: Data("account".utf8),
                        itemID: Data("item".utf8)
                    ),
                    title: title,
                    origins: ["https://example.com/login"],
                    credentials: [
                        .password(userName: "agent@example.com", password: "CANARY-SECRET")
                    ]
                )
            ],
            delta: MirrorDelta(addedItemIDs: [credentialID]),
            skippedCredentialCount: 0
        )
    }
}
