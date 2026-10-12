import AgentKeyringTestSupport
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Example login setting")
struct ExampleCredentialTests {
    @Test("The example is on by default, does not count and does not hide first-run setup")
    func defaultExample() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: CredentialAccessPolicyStore(
            fileURL: fixture.directory.appendingPathComponent("policies.json"), signer: fixture.signer))
        let model = fixture.model()
        await model.loadStatus()
        #expect(model.includeExampleCredential)
        #expect(model.status == nil)
        let request = AgentBridgeRequest(action: .status)

        let response = try await sendTestAgentRequest(request, model: model, bridge: fixture.bridge)
        #expect(response.ok)
        #expect(response.mirror == nil)
        #expect(response.message == "No mirror has been imported yet.")
        #expect(model.accessControl.rows.map(\.id) == [MirrorItem.exampleCredentialID])
        #expect(model.accessControl.count(for: .ask) == 0)
        await model.setIncludeExampleCredential(false)
        #expect(model.accessControl.rows.isEmpty)
        let reloaded = fixture.model()
        await reloaded.loadStatus()
        #expect(!reloaded.includeExampleCredential)
        #expect(reloaded.accessControl.rows.isEmpty)
        await reloaded.setIncludeExampleCredential(true)
        #expect(reloaded.accessControl.rows.count == 1)
        #expect(reloaded.status == nil)
    }

    @Test("Only Debug builds expose the example login on loopback", arguments: ["http://127.0.0.1:8443", "http://localhost:8443"])
    func loopbackExample(origin: String) throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let generation = try #require(fixture.model().generationIncludingExample(nil))
        let candidates = try CredentialResolver().candidates(in: generation, targetURL: origin)
        #if DEBUG
        #expect(candidates.map(\.id) == [MirrorItem.exampleCredentialID])
        #else
        #expect(candidates.isEmpty)
        #endif
        #expect(generation.safeStatus.credentialItemCount == 0)
    }

    @Test("The example is excluded from mirror and access-rule counts")
    func countsExcludeExample() {
        let item = MirrorItem(id: MirrorItem.exampleCredentialID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "example.com", origins: ["https://example.com"],
            credentials: [.password(userName: "example@example.com", password: "example-password")])
        let generation = MirrorGeneration(id: UUID(), previousGenerationID: nil, createdAt: Date(),
            sourceExportedAt: Date(), scope: .full, exporterIdentifier: "fixture",
            exporterDisplayName: "Fixture", items: [item], skippedCredentialCount: 0)
        #expect(generation.safeStatus.credentialItemCount == 0)
    }
}

@MainActor
private struct Fixture {
    let signer = FakeAccessRulesSigner()
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
    let settingsName = "ExampleCredentialTests-\(UUID().uuidString)"

    var bridge: AgentBridgeDirectory {
        AgentBridgeDirectory(rootURL: directory.appendingPathComponent("bridge"))
    }

    func model() -> MirrorAppModel {
        MirrorAppModel(store: EncryptedSnapshotStore(directoryURL: directory,
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x5A, count: 32))),
            bridge: bridge,
            accessControl: CredentialAccessController(store: CredentialAccessPolicyStore(
                fileURL: directory.appendingPathComponent("policies.json"), signer: signer)),
            settings: UserDefaults(suiteName: settingsName)!)
    }

    func cleanUp() {
        UserDefaults(suiteName: settingsName)?.removePersistentDomain(forName: settingsName)
        try? FileManager.default.removeItem(at: directory)
    }
}
