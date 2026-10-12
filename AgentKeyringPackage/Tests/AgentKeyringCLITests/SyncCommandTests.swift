import AgentKeyringFeature
import ArgumentParser
import Foundation
import Testing
@testable import AgentKeyringCLI

@Suite("Sync CLI")
struct SyncCommandTests {
    @Test("Sync accepts a site and sends the sync action")
    func parsing() throws {
        let command = try #require(AgentKeyringCLI.parseAsRoot(["sync", "example.com"]) as? Sync)
        #expect(command.site == "example.com")
        #expect(CLICommand.sync(targetURL: "https://example.com").request.action == .sync)
        #expect(throws: (any Error).self) { _ = try AgentKeyringCLI.parseAsRoot(["sync"]) }
    }

    @MainActor
    @Test("Successful sync prints one plain line")
    func output() async throws {
        let output = Pipe()
        let diagnostics = Pipe()
        try await CLIClient.run(.sync(targetURL: "https://example.com"),
            output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
            sendRequest: { request in
                #expect(request.action == .sync)
                #expect(request.targetURL == "https://example.com")
                return AgentBridgeResponse(id: request.id, ok: true)
            })
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            == "Josh has been asked to update Agent Keyring’s copy of your passwords.\n")
        #expect(diagnostics.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test("Find flags a possibly stale login")
    func staleFind() throws {
        let candidate = CredentialCandidate(id: UUID(), title: "Example", username: "synthetic",
            origins: ["https://example.com"], availableFields: [.password], possiblyStale: true)
        let response = AgentBridgeResponse(id: UUID(), ok: true,
            mirror: AgentMirrorSummary(importedAt: Date(), ageSeconds: 0, credentialCount: 1), candidates: [candidate])
        #expect(try CLIOutput.render(response, for: .find(targetURL: "https://example.com", account: nil))
            .contains("Possibly stale: this login was rejected"))
    }
}
