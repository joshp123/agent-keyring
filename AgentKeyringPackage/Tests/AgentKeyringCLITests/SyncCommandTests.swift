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
        try await MacOwner.$fullName.withValue("Alex Example") {
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
                == "Alex has been asked to update Agent Keyring’s copy of Apple Passwords.\n")
            #expect(diagnostics.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
    }

    @Test("Sync help includes the command, example, and its exit codes")
    func help() {
        MacOwner.$fullName.withValue("Alex Example") {
            let root = AgentKeyringCLI.helpMessage(columns: 100)
            #expect(root.contains("agent-keyring sync example.com"))
            let help = Sync.helpMessage(columns: 100)
            #expect(help.contains("sync <site>"))
            for meaning in [
                "0  Alex has been asked to update the copy.",
                "1  No matching login, no mirror, app unavailable, or notification failed.",
                "3  The request expired with no answer.",
                "64 Invalid command or arguments.",
            ] { #expect(help.contains(meaning)) }
        }
    }

    @MainActor
    @Test("Sync errors do not claim the owner was asked", arguments: [AgentBridgeErrorCode.notFound, .internalError, .requestExpired])
    func failedSync(code: AgentBridgeErrorCode) async throws {
        let output = Pipe()
        let diagnostics = Pipe()
        do {
            try await CLIClient.run(.sync(targetURL: "https://example.com"),
                output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
                sendRequest: { request in AgentBridgeResponse(id: request.id, ok: false, error: code) })
            Issue.record("Sync failure must return an error")
        } catch let exit as ExitCode { #expect(exit.rawValue == (code == .requestExpired ? 3 : 1)) }
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(!diagnostics.fileHandleForReading.readDataToEndOfFile().isEmpty)
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
