import AgentKeyringFeature
import ArgumentParser
import Foundation
import Darwin
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
        let help = Acquire.helpMessage()
        #expect(help.contains("5 minutes"))
        #expect(help.contains("Clear the reference"))
        #expect(CLICommand.acquire(field: .password, targetURL: "https://example.com", account: nil,
            credentialID: nil).request.callerPID == getpid())
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
        try CLIClient.clear(reference: reference, diagnostics: diagnostics.fileHandleForWriting)
        try CLIClient.clear(reference: reference, diagnostics: diagnostics.fileHandleForWriting)
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

    @Test("Fresh CLI processes read retained bytes until explicit clear", arguments: ["synthetic-pässword", "value ending with a newline\n", ""])
    func executableReadAndClear(value: String) throws {
        var directory = Bundle(for: CLIExecutableTestBundle.self).bundleURL.deletingLastPathComponent()
        var executable: URL?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("agent-keyring")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                executable = candidate
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        let cli = try #require(executable)
        let reference = UUID()
        defer { CredentialTransfer.clear(requestID: reference) }
        try CredentialTransfer.publish(value, requestID: reference)
        func run(_ command: String) throws -> (Int32, Data) {
            let process = Process()
            process.executableURL = cli
            process.arguments = [command, reference.uuidString]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
        }
        for _ in 0..<2 {
            let result = try run("read")
            #expect(result.0 == 0)
            #expect(result.1 == Data(value.utf8))
        }
        #expect(try run("clear").0 == 0)
        #expect(try run("clear").0 == 0)
        let cleared = try run("read")
        #expect(cleared.0 != 0)
        #expect(cleared.1.isEmpty)
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

    @Test("Native approval failure reaches stderr unchanged without retry", arguments: [
        "Credential approval failed (LocalAuthentication -4). Nothing was released.",
        "Another credential request is already awaiting approval.",
        "Touch ID or Apple Watch approval is not available.",
        "Agent Keyring could not show its approval window.",
    ])
    func approvalFailureMessage(message: String) async throws {
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
                    return AgentBridgeResponse(id: request.id, ok: false,
                        error: .authorizationUnavailable, message: message)
                }
            )
            Issue.record("Failed approval should exit nonzero")
        } catch let exit as ExitCode { #expect(exit.rawValue != 0) }
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        #expect(requests == 1)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == message + "\n")
    }

    private func read(_ reference: UUID, diagnostics: FileHandle) throws -> Data {
        let output = Pipe()
        try CLIClient.read(reference: reference, output: output.fileHandleForWriting, diagnostics: diagnostics)
        try output.fileHandleForWriting.close()
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}

private final class CLIExecutableTestBundle {}
