import AgentKeyringTestSupport
import AgentKeyringFeature
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("Browser approval survives plugin timeout")
struct AgentBrowserApprovalTests {
    @Test("Grant fills and automatic logins produce no CLI approval line", arguments: [false, true])
    func silentRelease(useGrant: Bool) async throws {
        let fixture = BrowserApprovalFixture()
        defer { fixture.cleanUp() }
        if useGrant { fixture.grants.approve(fixture.loginID, action: .acquire, session: syntheticRequester.session!, site: "example.com", account: "synthetic@example.com") }
        else { try await fixture.setPolicy(.allowAutomatically) }
        let diagnostics = Pipe()
        try await fixture.acquireWithCLI(diagnostics: diagnostics.fileHandleForWriting)
        try diagnostics.fileHandleForWriting.close()
        #expect(diagnostics.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(fixture.authorizer.calls == 0)
    }

    @Test("The plugin answers within twelve seconds; approval and retry then fill from the grant")
    func pendingThenRetry() async throws {
        try await MacOwner.$fullName.withValue("Alex Example") {
            let fixture = BrowserApprovalFixture()
            defer { fixture.cleanUp() }
            let start = ContinuousClock.now
            let pending = try await fixture.invoke()
            let elapsed = start.duration(to: .now)
            #expect(elapsed < .seconds(12))
            #expect(elapsed >= .seconds(10))
            #expect(pending["success"] as? Bool == false)
            #expect(pending["credential"] == nil)
            let askedAt = try #require(fixture.authorizer.requestedAt)
            #expect(pending["error"] as? String ==
                "Waiting for Alex's approval (asked at \(approvalTime(askedAt))); retry the login after Alex approves")
            #expect(fixture.deadlines.count == 3)
            #expect(Set(fixture.deadlines).count == 1)
            #expect(fixture.authorizer.calls == 1)
            let passwordRequest = try #require(fixture.requests.last)
            #expect(fixture.activeRequests.contains(passwordRequest.id))
            #expect(passwordRequest.bufferPublicationDeadline == fixture.deadlines.last)
            let usernameRequest = try #require(fixture.requests.first(where: { $0.field == .username }))
            #expect(throws: CredentialTransferError.unavailable) {
                _ = try CredentialTransfer.read(requestID: usernameRequest.id)
            }

            fixture.authorizer.approve()
            while fixture.responses[passwordRequest.id] == nil { await Task.yield() }
            #expect(fixture.grants.contains(fixture.loginID, action: .acquire, session: syntheticRequester.session!))
            for request in [usernameRequest, passwordRequest] {
                #expect(throws: CredentialTransferError.unavailable) {
                    _ = try CredentialTransfer.read(requestID: request.id)
                }
            }
            let receipt = try #require(fixture.responses[passwordRequest.id])
            #expect(!receipt.ok)
            #expect(receipt.copiedField == nil)
            let retry = try await fixture.invoke()
            #expect(retry["success"] as? Bool == true)
            #expect((retry["credential"] as? [String: String])?["username"] == "synthetic@example.com")
            #expect((retry["credential"] as? [String: String])?["password"] == "synthetic-browser-password")
            #expect(fixture.authorizer.calls == 1)

            await fixture.accessControl.setPolicy(.block, for: [fixture.loginID])
            let blocked = try await fixture.invoke()
            #expect(blocked["success"] as? Bool == false)
            #expect(blocked["credential"] == nil)
            #expect(blocked["error"] as? String == "Access to this login is blocked in Agent Keyring.")
            #expect(fixture.authorizer.calls == 1)
        }
    }
}

@MainActor
private final class BrowserApprovalFixture {
    let loginID = UUID()
    let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
    let authorizer = BrowserFakeAuthorizer()
    let grants = CredentialApprovalGrants()
    var requests: [AgentBridgeRequest] = []
    var deadlines: [Date] = []
    var listener: AgentBridgeServer?
    var activeRequests: Set<UUID> = []
    var responses: [UUID: AgentBridgeResponse] = [:]
    private(set) lazy var bridge = AgentBridgeDirectory(rootURL: root)
    private var preparedRules = false
    private lazy var policyStore = CredentialAccessPolicyStore(fileURL: root.appendingPathComponent("policies.json"),
        signer: FakeAccessRulesSigner())
    private(set) lazy var accessControl = CredentialAccessController(
        store: policyStore)
    private lazy var processor = AgentCredentialReleaseProcessor(accessControl: accessControl,
        grants: grants, approvals: CredentialApprovalCoordinator(lockState: BrowserUnlockedSession()))
    private lazy var generation = MirrorGeneration(id: UUID(), previousGenerationID: nil,
        createdAt: Date(), sourceExportedAt: Date(), scope: .full, exporterIdentifier: "fixture",
        exporterDisplayName: "Fixture", items: [MirrorItem(id: loginID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "Synthetic browser login", origins: ["https://example.com"], credentials: [
                .password(userName: "synthetic@example.com", password: "synthetic-browser-password")
            ])], skippedCredentialCount: 0)

    func invoke() async throws -> [String: Any] {
        try await prepareRules()
        let input = Pipe()
        let output = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data("""
        {"protocol":"agent-browser.plugin.v1","type":"credential.resolve","capability":"credential.read","request":{"itemRef":"example.com","url":"https://example.com/login"}}
        """.utf8))
        try input.fileHandleForWriting.close()
        await AgentBrowserPluginProtocol.run(input: input.fileHandleForReading,
            output: output.fileHandleForWriting, sendRequest: { request, deadline in
                self.requests.append(request)
                self.deadlines.append(deadline)
                if request.action == .resolve {
                    return AgentBridgeResponse(id: request.id, ok: true,
                        candidates: try CredentialResolver().candidates(in: self.generation, targetURL: "https://example.com"))
                }
                try self.startListener()
                return try await AgentBridgeClient(bridge: self.bridge).send(request, waitUntil: deadline) { _ in
                    Issue.record("The listener is already running")
                }
            })
        try output.fileHandleForWriting.close()
        return try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    }

    func setPolicy(_ policy: CredentialAccessPolicy) async throws {
        try await prepareRules()
        await accessControl.refresh(from: generation)
        await accessControl.setPolicy(policy, for: [loginID])
    }

    func acquireWithCLI(diagnostics: FileHandle) async throws {
        try await prepareRules()
        try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com",
            account: nil, credentialID: loginID), output: FileHandle.nullDevice, diagnostics: diagnostics,
            sendRequest: { request in
                self.requests.append(request)
                return try await self.processor.release(request: request, requester: syntheticRequester, generation: self.generation,
                    authorize: { _, _ in Issue.record("Unprompted release asked for approval") })
            })
    }

    private func prepareRules() async throws {
        guard !preparedRules else { return }
        try await confirmInitialAccessRules(in: policyStore)
        preparedRules = true
    }

    private func startListener() throws {
        guard listener == nil else { return }
        listener = try AgentBridgeServer(bridge: bridge) { request, _, progress in
            self.activeRequests.insert(request.id)
            defer { self.activeRequests.remove(request.id) }
            let response: AgentBridgeResponse
            do {
                response = try await self.processor.release(request: request, requester: syntheticRequester, generation: self.generation,
                    onProgress: {
                        self.authorizer.requestedAt = $0.askedAt
                        progress($0)
                    }, authorize: { try await self.authorizer.authorize($0, onPromptStarted: $1) })
            } catch let failure as AgentBridgeFailure {
                response = AgentBridgeResponse(id: request.id, ok: false, error: failure.code)
            }
            self.responses[request.id] = response
            return response
        }
    }

    func cleanUp() {
        listener = nil
        for request in requests { CredentialTransfer.clear(requestID: request.id) }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class BrowserFakeAuthorizer: CredentialReleaseAuthorizing {
    var requestedAt: Date?
    var calls = 0
    private var continuation: CheckedContinuation<Void, Error>?

    func authorize(_ request: CredentialReleaseAuthorizationRequest, onPromptStarted: @escaping () -> Void) async throws {
        calls += 1
        onPromptStarted()
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func approve() {
        continuation?.resume()
        continuation = nil
    }
}

private struct BrowserUnlockedSession: CredentialSessionLockState {
    var isLocked: Bool { false }
}
