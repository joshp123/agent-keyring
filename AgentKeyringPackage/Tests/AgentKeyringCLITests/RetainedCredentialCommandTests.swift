import AgentKeyringFeature
import ArgumentParser
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("Acquire, read and clear retained credentials")
struct RetainedCredentialCommandTests {
    @Test("The CLI exposes acquire, read and clear")
    func arguments() throws {
        let command = try #require(AgentKeyringCLI.parseAsRoot([
            "acquire", "password", "https://example.com/login", "--account", "synthetic@example.com",
        ]) as? Acquire)
        #expect(command.field == .password)
        #expect(command.account == "synthetic@example.com")
        let reference = UUID().uuidString
        #expect(try AgentKeyringCLI.parseAsRoot(["read", reference]) is Read)
        #expect(try AgentKeyringCLI.parseAsRoot(["clear", reference]) is Clear)
        #expect(throws: (any Error).self) {
            _ = try AgentKeyringCLI.parseAsRoot([
                "acquire", "password", "example.com", "--account", "synthetic",
                "--credential", UUID().uuidString,
            ])
        }
    }

    @Test("One acquisition supports repeated exact reads until explicit clear", arguments: ["synthetic-pässword", "value ending with a newline\n", ""])
    func retainedValue(value: String) async throws {
        let output = Pipe()
        let diagnostics = Pipe()
        var requests = 0
        var acquiredReference: UUID?
        try await CLIClient.run(
            .acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting,
            sendRequest: { request in
                requests += 1
                acquiredReference = request.id
                #expect(request.action == .acquire)
                try CredentialTransfer.publish(value, requestID: request.id)
                return AgentBridgeResponse(id: request.id, ok: true)
            }
        )
        let reference = try #require(acquiredReference)
        defer { CredentialTransfer.clear(requestID: reference) }
        try output.fileHandleForWriting.close()
        #expect(output.fileHandleForReading.readDataToEndOfFile() == Data((reference.uuidString + "\n").utf8))
        for _ in 0..<2 {
            #expect(try read(reference, diagnostics: diagnostics.fileHandleForWriting) == Data(value.utf8))
        }
        CredentialTransfer.clear(requestID: reference)
        CredentialTransfer.clear(requestID: reference)
        let afterClear = Pipe()
        do {
            try CLIClient.read(reference: reference, output: afterClear.fileHandleForWriting,
                diagnostics: diagnostics.fileHandleForWriting)
            Issue.record("Read after clear should fail")
        } catch let exit as ExitCode { #expect(exit.rawValue != 0) }
        try afterClear.fileHandleForWriting.close()
        #expect(afterClear.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(requests == 1)
    }

    @Test("Read supports file redirection and a failed output leaves the value available")
    func outputFailureDoesNotConsumeValue() throws {
        let reference = UUID()
        defer { CredentialTransfer.clear(requestID: reference) }
        try CredentialTransfer.publish("synthetic@example.com", requestID: reference)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        try CLIClient.read(reference: reference, output: output)
        try output.close()
        #expect(try Data(contentsOf: url) == Data("synthetic@example.com".utf8))
        let diagnostics = Pipe()
        do {
            try CLIClient.read(reference: reference, output: output, diagnostics: diagnostics.fileHandleForWriting)
            Issue.record("Closed output should fail")
        } catch let exit as ExitCode { #expect(exit.rawValue != 0) }
        #expect(try read(reference, diagnostics: diagnostics.fileHandleForWriting) == Data("synthetic@example.com".utf8))
    }

    @Test("Failed acquisition leaves stdout empty and does not retry", arguments: [AgentBridgeErrorCode.policyDenied, .authorizationDenied, .notFound])
    func failureOutput(code: AgentBridgeErrorCode) async throws {
        let output = Pipe()
        let diagnostics = Pipe()
        var requests = 0
        do {
            try await CLIClient.run(
                .acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
                output: output.fileHandleForWriting,
                diagnostics: diagnostics.fileHandleForWriting,
                sendRequest: { request in
                    requests += 1
                    return AgentBridgeResponse(id: request.id, ok: false, error: code)
                }
            )
            Issue.record("Failure should exit nonzero")
        } catch let exit as ExitCode { #expect(exit.rawValue != 0) }
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        #expect(requests == 1)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(!diagnostics.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    private func read(_ reference: UUID, diagnostics: FileHandle) throws -> Data {
        let output = Pipe()
        try CLIClient.read(reference: reference, output: output.fileHandleForWriting, diagnostics: diagnostics)
        try output.fileHandleForWriting.close()
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}
