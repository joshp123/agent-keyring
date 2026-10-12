@testable import AgentKeyringFeature
import ArgumentParser
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("CLI rules confirmation")
struct RulesConfirmationTests {
    @Test("Every request reports exactly one sentence, empty stdout and exit 7", arguments: [
        "status", "find", "username", "password", "code",
    ])
    func confirmationOutput(commandName: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CredentialAccessPolicyStore(fileURL: root.appendingPathComponent("rules.json"),
            signer: FakeAccessRulesSigner())
        let loginID = UUID()
        try await store.save([loginID: .allowAutomatically])
        let signatureURL = await store.signatureURL
        try FileManager.default.moveItem(at: signatureURL, to: signatureURL.appendingPathExtension("held"))
        let settingsName = "RulesConfirmationCLITests-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: settingsName))
        defer { settings.removePersistentDomain(forName: settingsName) }
        let bridge = AgentBridgeDirectory(rootURL: root.appendingPathComponent("bridge"))
        let model = MirrorAppModel(store: EncryptedSnapshotStore(directoryURL: root.appendingPathComponent("vault"),
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x42, count: 32))),
            bridge: bridge, accessControl: CredentialAccessController(store: store), settings: settings)
        let command: CLICommand = switch commandName {
        case "status": .status
        case "find": .find(targetURL: "https://example.com", account: nil)
        default: .acquire(field: commandName == "username" ? .username : commandName == "password" ? .password : .totp,
            targetURL: "https://example.com", account: nil, credentialID: nil)
        }
        let output = Pipe()
        let diagnostics = Pipe()
        var exitCode: Int32 = 0
        do {
            try await CLIClient.run(command, output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
                sendRequest: { request in
                    try bridge.write(request)
                    await model.handleAgentRequest(id: request.id)
                    return try bridge.readResponse(id: request.id)
                })
        } catch let exit as ExitCode { exitCode = exit.rawValue }
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = diagnostics.fileHandleForReading.readDataToEndOfFile()
        #expect(stdout.isEmpty)
        #expect(String(decoding: stderr, as: UTF8.self) ==
            "Agent Keyring's access rules need Josh's confirmation in the app before anything is released.\n")
        #expect(exitCode == 7)
    }
}
