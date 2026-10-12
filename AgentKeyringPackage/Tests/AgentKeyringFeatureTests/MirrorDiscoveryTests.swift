import CryptoKit
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Mirror discovery")
struct MirrorDiscoveryTests {
    @Test("App status and find reuse metadata, repairing an older snapshot once", arguments: [false, true])
    func discoveryUsesOnlyMetadata(missingIndex: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedSnapshotStore(directoryURL: directory.appendingPathComponent("vault"),
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x42, count: 32)))
        let item = MirrorItem(id: UUID(), sourceIdentity: MirrorSourceIdentity(
            exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "Test login", origins: ["https://example.com"], credentials: [
                .password(userName: "synthetic-account", password: "SECRET-CANARY"),
                .totp(secret: Data("CODE-CANARY".utf8), period: 30, digits: 6,
                    userName: "synthetic-account", algorithm: .sha1, issuer: nil)])
        let generation = MirrorGeneration(id: UUID(), previousGenerationID: nil,
            createdAt: Date().addingTimeInterval(-8 * 86_400), sourceExportedAt: Date(),
            scope: .full, exporterIdentifier: "fixture", exporterDisplayName: "Fixture",
            items: [item], skippedCredentialCount: 0)
        let payload = await store.generationFileURL(for: generation.id)
        let metadataURL = payload.deletingPathExtension().appendingPathExtension("metadata")
        if missingIndex {
            try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let sealedBox = try AES.GCM.seal(JSONEncoder().encode(generation),
                using: SymmetricKey(data: Data(repeating: 0x42, count: 32)))
            try #require(sealedBox.combined).write(to: payload)
            try Data(generation.id.uuidString.utf8).write(
                to: directory.appendingPathComponent("vault/current"))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        } else {
            try await store.save(generation)
            try Data("corrupt secret payload".utf8).write(to: payload)
        }
        let bridge = AgentBridgeDirectory(rootURL: directory.appendingPathComponent("bridge"))
        let settingsName = "MirrorDiscoveryTests-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: settingsName))
        defer { settings.removePersistentDomain(forName: settingsName) }
        settings.set(false, forKey: "includeExampleCredential")
        let rulesSigner = FakeAccessRulesSigner()
        try await CredentialAccessPolicyStore(fileURL: directory.appendingPathComponent("policies.json"),
            signer: rulesSigner).save([:])
        let model = MirrorAppModel(store: store, bridge: bridge,
            accessControl: CredentialAccessController(store: CredentialAccessPolicyStore(
                fileURL: directory.appendingPathComponent("policies.json"), signer: rulesSigner)),
            settings: settings)
        await model.loadStatus()
        #expect(model.status == generation.safeStatus)
        #expect(model.notice == nil)
        #expect(FileManager.default.fileExists(atPath: metadataURL.path))
        let savedMetadata = try Data(contentsOf: metadataURL)
        if missingIndex {
            try Data("corrupt secret payload".utf8).write(to: payload)
        }
        for action in [AgentBridgeAction.status, .resolve] {
            let request = AgentBridgeRequest(action: action, targetURL: "https://example.com")
            try bridge.write(request)
            await model.handleAgentRequest(id: request.id)
            let response = try bridge.readResponse(id: request.id)
            #expect(response.ok)
            #expect(response.mirror?.credentialCount == 1)
            #expect(response.mirror?.ageSeconds ?? 0 >= 8 * 86_400)
            if action == .resolve {
                #expect(response.candidates?.first?.username == "synthetic-account")
                #expect(response.candidates?.first?.availableFields == [.username, .password, .totp])
            }
            let output = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            #expect(!output.contains("SECRET-CANARY"))
            #expect(!output.contains("CODE-CANARY"))
        }
        #expect(try Data(contentsOf: metadataURL) == savedMetadata)
    }
}
