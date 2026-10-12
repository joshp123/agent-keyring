import AgentKeyringFeature
import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("agent-browser credential plugin", .serialized)
struct AgentBrowserPluginTests {
    private let candidate = CredentialCandidate(
        id: UUID(), title: "Synthetic login", username: "synthetic@example.com",
        origins: ["https://example.com"], availableFields: [.username, .password]
    )

    @Test("The command is hidden and the manifest needs no app access")
    func manifest() async throws {
        #expect(try AgentKeyringCLI.parseAsRoot(["agent-browser-plugin"]) is AgentBrowserPlugin)
        #expect(!AgentKeyringCLI.helpMessage().contains("agent-browser-plugin"))
        let response = try await invoke(type: "plugin.manifest", capability: "plugin.manifest", request: [:]) { _ in
            Issue.record("The manifest must not contact the app")
            throw AgentBridgeFailure(.internalError, "unexpected bridge access")
        }
        #expect(response["protocol"] as? String == "agent-browser.plugin.v1")
        #expect(response["success"] as? Bool == true)
        let manifest = try #require(response["manifest"] as? [String: Any])
        #expect(manifest["name"] as? String == "agent-keyring")
        #expect(manifest["capabilities"] as? [String] == ["credential.read"])
        #expect(response["credential"] == nil)
    }

    @Test("Both fields use acquire for the destination and the same selected login", arguments: [
        "example.com", "example.com synthetic@example.com",
    ])
    func resolve(itemRef: String) async throws {
        var requests: [AgentBridgeRequest] = []
        let response = try await invoke(request: ["itemRef": itemRef, "url": "https://example.com/login?next=account"]) { request in
            requests.append(request)
            if request.action == .acquire {
                try CredentialTransfer.publish(request.field == .username ? "synthetic@example.com" : "synthetic-pässword\n", requestID: request.id, credentialID: UUID(), expiresAfter: 300)
            }
            return AgentBridgeResponse(id: request.id, ok: true, candidates: [candidate])
        }
        #expect(response["success"] as? Bool == true)
        let credential = try #require(response["credential"] as? [String: String])
        #expect(credential == ["username": "synthetic@example.com", "password": "synthetic-pässword\n", "url": "https://example.com/login?next=account"])
        #expect(requests.count == 3)
        #expect(requests[0].action == .resolve)
        #expect(requests[0].targetURL == "https://example.com")
        let expectedAccount = itemRef.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
        #expect(requests[0].usernameHint == expectedAccount)
        for request in requests.dropFirst() {
            #expect(request.action == .acquire)
            #expect(request.targetURL == credential["url"])
            #expect(request.candidateID == candidate.id)
            #expect(request.callerPID == getpid())
            #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: request.id) }
        }
        #expect(requests[1].field == .username)
        #expect(requests[2].field == .password)
    }

    @Test("Bridge failures return only a short error and clear partial releases", arguments: [
        AgentBridgeErrorCode.authorizationDenied, .authorizationInterrupted, .authorizationNotVerified, .policyDenied, .notFound, .fieldUnavailable,
        .ambiguous, .authorizationUnavailable, .bridgeUnavailable, .timedOut, .requestExpired,
        .mirrorUnavailable, .internalError, .invalidRequest, .invalidURL, .insecureOrigin, .invalidTOTP,
    ])
    func failure(code: AgentBridgeErrorCode) async throws {
        var references: [UUID] = []
        let response = try await invoke { request in
            if request.action == .resolve { return AgentBridgeResponse(id: request.id, ok: true, candidates: [candidate]) }
            references.append(request.id)
            try CredentialTransfer.publish("failure-secret-canary", requestID: request.id, credentialID: UUID(), expiresAfter: 300)
            return AgentBridgeResponse(id: request.id, ok: request.field == .username,
                error: code, message: "failure-secret-canary")
        }
        let expected: String = switch code {
        case .authorizationDenied: "Josh declined the request."
        case .authorizationNotVerified: "Touch ID or Apple Watch did not verify; retry the request."
        case .authorizationInterrupted: "macOS interrupted the approval prompt; retry the login."
        case .requestExpired: "The request expired with no answer."
        case .policyDenied: "Access to this login is blocked in Agent Keyring."
        case .notFound, .fieldUnavailable, .mirrorUnavailable: "no matching login"
        case .ambiguous: "ambiguous"
        default: "approval unavailable"
        }
        #expect(response["success"] as? Bool == false)
        #expect(response["error"] as? String == expected)
        #expect(response["credential"] == nil)
        #expect(!String(describing: response).contains("failure-secret-canary"))
        for reference in references {
            #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: reference) }
        }
    }

    @Test("Thrown bridge failures and unreadable buffers fail without a credential", arguments: ["throw", "missing buffer", "cancel"])
    func transportFailure(mode: String) async throws {
        var references: [UUID] = []
        let response = try await invoke { request in
            if request.action == .resolve { return AgentBridgeResponse(id: request.id, ok: true, candidates: [candidate]) }
            references.append(request.id)
            if request.field == .username || mode != "missing buffer" {
                try CredentialTransfer.publish("transport-secret-canary", requestID: request.id, credentialID: UUID(), expiresAfter: 300)
            }
            if request.field == .password {
                if mode == "throw" { throw AgentBridgeFailure(.authorizationUnavailable, "transport-secret-canary") }
                if mode == "cancel" { throw CancellationError() }
            }
            return AgentBridgeResponse(id: request.id, ok: true)
        }
        #expect(response["success"] as? Bool == false)
        #expect(response["error"] as? String == "approval unavailable")
        #expect(response["credential"] == nil)
        for reference in references {
            #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: reference) }
        }
    }

    @Test("Empty and ambiguous selections never acquire a field", arguments: [0, 2])
    func selection(count: Int) async throws {
        let response = try await invoke { request in
            #expect(request.action == .resolve)
            return AgentBridgeResponse(id: request.id, ok: true, candidates: Array(repeating: candidate, count: count))
        }
        #expect(response["success"] as? Bool == false)
        #expect(response["error"] as? String == (count == 0 ? "no matching login" : "ambiguous"))
    }

    @Test("An omitted or null URL uses the item site", arguments: [false, true])
    func siteURL(includeNull: Bool) async throws {
        var request: [String: Any] = ["itemRef": "example.com"]
        if includeNull { request["url"] = NSNull() }
        let response = try await invoke(bytes: JSONSerialization.data(withJSONObject: [
            "protocol": "agent-browser.plugin.v1", "type": "credential.resolve", "capability": "credential.read",
            "request": request,
        ])) { request in
            #expect(request.targetURL == "https://example.com")
            if request.action == .acquire {
                try CredentialTransfer.publish(request.field == .username ? "synthetic@example.com" : "synthetic-password", requestID: request.id, credentialID: UUID(), expiresAfter: 300)
            }
            return AgentBridgeResponse(id: request.id, ok: true, candidates: [candidate])
        }
        #expect(response["success"] as? Bool == true)
        #expect((response["credential"] as? [String: String])?["url"] == "https://example.com")
    }

    @Test("Invalid requests never contact the app", arguments: [
        "{}", "not json",
        "{\"protocol\":\"wrong\",\"type\":\"plugin.manifest\",\"capability\":\"plugin.manifest\",\"request\":{}}",
        "{\"protocol\":\"agent-browser.plugin.v1\",\"type\":\"credential.resolve\",\"capability\":\"credential.read\",\"request\":{}}",
        "{\"protocol\":\"agent-browser.plugin.v1\",\"type\":\"credential.resolve\",\"capability\":\"credential.read\",\"request\":{\"itemRef\":\"example.com \",\"url\":\"https://example.com\"}}",
        "{\"protocol\":\"agent-browser.plugin.v1\",\"type\":\"credential.resolve\",\"capability\":\"credential.read\",\"request\":{\"itemRef\":\"example.com\",\"url\":\"http://example.com\"}}",
    ])
    func invalid(input: String) async throws {
        let response = try await invoke(bytes: Data(input.utf8)) { _ in
            Issue.record("Invalid input must not contact the app")
            throw CancellationError()
        }
        #expect(response["success"] as? Bool == false)
        #expect(response["credential"] == nil)
    }

    @Test("The canary appears only in the stdout credential, never stderr or bridge metadata")
    func canary() async throws {
        let canary = "plugin-secret-canary-" + UUID().uuidString
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: [
            "protocol": "agent-browser.plugin.v1", "type": "credential.resolve", "capability": "credential.read",
            "request": ["itemRef": "example.com", "url": "https://example.com/login"],
        ]))
        try input.fileHandleForWriting.close()
        let output = Pipe()
        let diagnostics = Pipe()
        let savedStdout = dup(STDOUT_FILENO)
        let savedStderr = dup(STDERR_FILENO)
        #expect(savedStdout >= 0)
        #expect(savedStderr >= 0)
        dup2(output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(diagnostics.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        defer {
            dup2(savedStdout, STDOUT_FILENO); close(savedStdout)
            dup2(savedStderr, STDERR_FILENO); close(savedStderr)
        }
        var metadata = Data()
        var references: [UUID] = []
        await AgentBrowserPluginProtocol.run(input: input.fileHandleForReading) { request, _ in
            metadata.append(try JSONEncoder().encode(request))
            if request.action == .acquire {
                references.append(request.id)
                try CredentialTransfer.publish(request.field == .password ? canary : "synthetic@example.com", requestID: request.id, credentialID: UUID(), expiresAfter: 300)
            }
            let receipt = AgentBridgeResponse(id: request.id, ok: true, candidates: [candidate])
            metadata.append(try JSONEncoder().encode(receipt))
            return receipt
        }
        dup2(savedStdout, STDOUT_FILENO)
        dup2(savedStderr, STDERR_FILENO)
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        let response = try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        #expect((response["credential"] as? [String: String])?["password"] == canary)
        #expect(metadata.range(of: Data(canary.utf8)) == nil)
        #expect(diagnostics.fileHandleForReading.readDataToEndOfFile().range(of: Data(canary.utf8)) == nil)
        for reference in references {
            #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: reference) }
        }
    }

    private func invoke(
        type: String = "credential.resolve", capability: String = "credential.read",
        request: [String: String] = ["itemRef": "example.com", "url": "https://example.com/login"],
        sendRequest: (AgentBridgeRequest) async throws -> AgentBridgeResponse
    ) async throws -> [String: Any] {
        try await invoke(bytes: JSONSerialization.data(withJSONObject: [
            "protocol": "agent-browser.plugin.v1", "type": type, "capability": capability, "request": request,
        ]), sendRequest: sendRequest)
    }

    private func invoke(
        bytes: Data, sendRequest: (AgentBridgeRequest) async throws -> AgentBridgeResponse
    ) async throws -> [String: Any] {
        let input = Pipe()
        let output = Pipe()
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
        await AgentBrowserPluginProtocol.run(input: input.fileHandleForReading,
            output: output.fileHandleForWriting, sendRequest: { request, _ in try await sendRequest(request) })
        try output.fileHandleForWriting.close()
        return try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    }
}
