import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Credential access policies")
struct CredentialAccessPolicyTests {
    @MainActor
    @Test("New credentials ask, automatic access skips approval, and blocked access fails closed")
    func releaseDecisions() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.store.save([:])
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
    func persistenceAcrossRefresh() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let first = fixture.generation()
        let credentialID = first.items[0].id
        try await fixture.store.save([:])
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
    func fuzzySearch() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.store.save([:])
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
    func bulkRecommendations() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.store.save([:])
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

    @MainActor
    @Test("A 522-credential mirror keeps all groups, search results, and stable endpoints")
    func fullScaleAccessModel() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.store.save([:])
        let controller = CredentialAccessController(store: fixture.store)
        let generation = fixture.generation(count: 522)
        await controller.refresh(from: generation)

        let assignments = Dictionary(uniqueKeysWithValues: generation.items.enumerated().compactMap {
            index, item -> (UUID, CredentialAccessPolicy)? in
            if (440..<492).contains(index) { return (item.id, .allowAutomatically) }
            if index >= 492 { return (item.id, .block) }
            return nil
        })
        await controller.setPolicies(assignments)

        #expect(controller.count(for: .ask) == 440)
        #expect(controller.count(for: .allowAutomatically) == 52)
        #expect(controller.count(for: .block) == 30)
        #expect(controller.visibleRows.first?.title == "Credential 1")
        #expect(controller.visibleRows.last?.title == "Credential 440")

        controller.searchText = "service-522.example"
        #expect(controller.visibleRows.isEmpty)
        controller.selectedPolicy = .block
        #expect(controller.visibleRows.map(\.title) == ["Credential 522"])

        await controller.setPolicy(.ask, for: [generation.items[521].id])
        #expect(controller.count(for: .ask) == 441)
        #expect(controller.count(for: .block) == 29)
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
        let bytes = Data(json.utf8)
        try bytes.write(to: fixture.fileURL)
        try FakeAccessRulesSigner().signature(for: bytes).write(to: fixture.fileURL.appendingPathExtension("signature"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.fileURL.path
        )

        await #expect(throws: AccessRulesConfirmationRequired.self) {
            try await fixture.store.load()
        }
    }

    @Test("Every save signs the exact stored bytes and keeps the signature owner-only")
    func signedSave() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store
        for policy in [CredentialAccessPolicy.block, .allowAutomatically, .ask] {
            try await store.save([UUID(): policy])
            let bytes = try Data(contentsOf: fixture.fileURL)
            let signatureURL = await store.signatureURL
            #expect(try FakeAccessRulesSigner().verify(Data(contentsOf: signatureURL), for: bytes))
            let attributes = try FileManager.default.attributesOfItem(atPath: signatureURL.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test("Cancelled signing leaves the previously saved rules and signature intact")
    func cancelledSave() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try await fixture.store.save([UUID(): .block])
        let bytes = try Data(contentsOf: fixture.fileURL)
        let signatureURL = await fixture.store.signatureURL
        let signature = try Data(contentsOf: signatureURL)
        let store = CredentialAccessPolicyStore(fileURL: fixture.fileURL,
            signer: FakeAccessRulesSigner(refusesSigning: true))
        await #expect(throws: CocoaError.self) { try await store.save([UUID(): .allowAutomatically]) }
        #expect(try Data(contentsOf: fixture.fileURL) == bytes)
        #expect(try Data(contentsOf: signatureURL) == signature)
    }
}

private struct Fixture {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentKeyringPolicyTests-\(UUID().uuidString)", isDirectory: true)

    var fileURL: URL {
        directoryURL.appendingPathComponent("access-policies.json")
    }

    var store: CredentialAccessPolicyStore {
        CredentialAccessPolicyStore(fileURL: fileURL, signer: FakeAccessRulesSigner())
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
            skippedCredentialCount: 0
        )
    }

    func generation(count: Int) -> MirrorGeneration {
        let items = (1...count).map { number in
            let id = UUID()
            return MirrorItem(
                id: id,
                sourceIdentity: MirrorSourceIdentity(
                    exporterIdentifier: "com.apple.Passwords",
                    accountID: Data("account-\(number)".utf8),
                    itemID: Data("item-\(number)".utf8)
                ),
                title: "Credential \(number)",
                origins: ["https://service-\(number).example/login"],
                credentials: [
                    .password(userName: "account-\(number)", password: "SYNTHETIC")
                ]
            )
        }
        return MirrorGeneration(
            id: UUID(),
            previousGenerationID: nil,
            createdAt: Date(timeIntervalSince1970: 2_000),
            sourceExportedAt: Date(timeIntervalSince1970: 1_900),
            scope: .full,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: items,
            skippedCredentialCount: 0
        )
    }
}
