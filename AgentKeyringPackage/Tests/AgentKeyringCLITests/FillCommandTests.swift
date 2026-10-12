import AgentKeyringFeature
import AgentKeyringFillerSupport
import AgentKeyringTestSupport
import ArgumentParser
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("Fill CLI")
struct FillCommandTests {
    @Test("Fill accepts all fields and an account", arguments: ["username", "password", "code"])
    func arguments(field: String) throws {
        let command = try #require(AgentKeyringCLI.parseAsRoot(["fill", field, "example.com", "--account", "example@example.com"]) as? Fill)
        try command.validate()
        #expect(command.account == "example@example.com")
        #expect(command.field.rawValue == field)
        let bridgeCommand = CLICommand.fill(field: command.field.bridgeField, targetURL: "https://example.com", account: command.account)
        #expect(bridgeCommand.request.action == .fill)
        #expect(bridgeCommand.request.field == command.field.bridgeField)
    }

    @Test("Fill accepts a credential ID and rejects invalid or conflicting selectors")
    func credentialSelector() throws {
        let id = UUID()
        let command = try #require(AgentKeyringCLI.parseAsRoot(["fill", "password", "example.com", "--credential", id.uuidString]) as? Fill)
        #expect(command.credential == id.uuidString)
        let request = CLICommand.fill(field: .password, targetURL: "https://example.com", account: nil, credentialID: id).request
        #expect(request.candidateID == id && request.action == .fill)
        #expect(throws: (any Error).self) {
            try AgentKeyringCLI.parseAsRoot(["fill", "password", "example.com", "--credential", "not-a-uuid"])
        }
        #expect(throws: (any Error).self) {
            try AgentKeyringCLI.parseAsRoot(["fill", "password", "example.com", "--credential", id.uuidString, "--account", "same-account"])
        }
        #expect(Fill.helpMessage().contains("--credential"))
    }

    @Test("Duplicate accounts suggest fill with a credential ID")
    func duplicateAccountSuggestion() {
        let candidate = CredentialCandidate(id: UUID(), title: "Duplicate", username: "same-account",
            origins: ["https://example.com"], availableFields: [.password])
        let response = AgentBridgeResponse(id: UUID(), ok: false, error: .ambiguous, candidates: [candidate, candidate])
        let error = CLIError(response: response, command: .fill(field: .password, targetURL: "https://example.com", account: nil))
        #expect(error.rendered.contains("agent-keyring fill password 'https://example.com' --credential UUID"))
    }

    @Test("Fill validates the secure site and missing arguments")
    func invalidArguments() throws {
        #expect(throws: (any Error).self) { try AgentKeyringCLI.parseAsRoot(["fill", "password"]) }
        #expect(throws: (any Error).self) { try AgentKeyringCLI.parseAsRoot(["fill", "password", "http://example.com"]) }
    }

    @Test("Each fill result is a sentence with the documented exit", arguments: [
        "filled", "field", "mismatch", "browser", "address", "permission", "locked", "changed",
    ])
    func results(path: String) async throws {
        let error: AgentBridgeErrorCode? = switch path {
        case "field": .wrongFocusedField
        case "mismatch": .pageMismatch
        case "browser": .unsupportedBrowser
        case "address": .unreadablePageAddress
        case "permission": .accessibilityMissing
        case "locked": .screenLocked
        case "changed": .fillTargetChanged
        default: nil
        }
        let expectedExit: Int32 = switch path {
        case "field": 8
        case "mismatch": 9
        case "browser", "address": 10
        case "permission": 11
        case "locked": 12
        case "changed": 13
        default: 0
        }
        let expectedSentence = switch path {
        case "field": "Focus a secure password field, then retry."
        case "mismatch": "The page host example.com.evil.invalid does not match the saved site example.com."
        case "browser": "This browser is not supported; use agent-browser."
        case "address": "This browser's page address cannot be read; use agent-browser."
        case "permission": "Grant Agent Keyring Accessibility in System Settings → Privacy & Security → Accessibility."
        case "locked": "The screen is locked."
        case "changed": "The browser, page or focused field changed; focus the field and retry."
        default: "Filled."
        }
        let output = Pipe(), diagnostics = Pipe()
        var exit: Int32 = 0
        do {
            try await CLIClient.run(.fill(field: .password, targetURL: "https://example.com", account: nil),
                output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
                sendRequest: { request in AgentBridgeResponse(id: request.id, ok: error == nil,
                    error: error, message: expectedSentence, filledField: error == nil ? .password : nil) })
        } catch let result as ExitCode { exit = result.rawValue }
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(exit == expectedExit)
        #expect(stdout == (error == nil ? "Filled.\n" : ""))
        #expect(stderr == (error == nil ? "" : expectedSentence + "\n"))
    }

    @Test("Both help screens document fill and every fill exit")
    func help() {
        for help in [AgentKeyringCLI.helpMessage(columns: 160), Fill.helpMessage(columns: 160)] {
            for code in ["8  No field", "9  The page", "10 This browser", "11 Accessibility", "12 The screen", "13 The browser"] {
                #expect(help.contains(code))
            }
            #expect(help.contains("agent-browser"))
        }
        #expect(AgentKeyringCLI.helpMessage().contains("agent-keyring fill password example.com"))
    }

    @Test("The app-to-CLI canary stays only in the fake filler", arguments: [AgentCredentialField.password, .username, .totp])
    func canary(field: AgentCredentialField) async throws {
        let filler = FakeCredentialFiller(inspection: fillInspection(focusedSubrole: field == .password ? "AXSecureTextField" : nil))
        let fixture = try FillTestFixture(policy: .ask, filler: filler)
        defer { fixture.cleanUp() }
        let output = Pipe(), diagnostics = Pipe()
        let command = CLICommand.fill(field: field, targetURL: "https://example.com", account: nil)
        try await CLIClient.run(command, output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
            sendRequest: { request in
                try fixture.bridge.write(request)
                let response = try await fixture.processor.release(request: request, generation: fixture.generation,
                    authorize: { _, onPromptStarted in onPromptStarted() })
                try fixture.bridge.write(response)
                let serializedResponse = try Data(contentsOf: fixture.bridge.rootURL.appendingPathComponent("\(request.id.uuidString).response.json"))
                #expect(!String(decoding: serializedResponse, as: UTF8.self).contains(filler.typedValues[0]))
                #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: request.id) }
                return try fixture.bridge.readResponse(id: request.id)
            })
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(stdout == "Filled.\n")
        #expect(field == .username ? stderr.isEmpty : stderr.hasPrefix("Approved at "))
        #expect(filler.typedValues.count == 1)
        #expect(!stdout.contains(filler.typedValues[0]) && !stderr.contains(filler.typedValues[0]))
    }
}
