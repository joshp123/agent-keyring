import AgentKeyringFeature
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("Browser approval survives plugin timeout")
struct AgentBrowserApprovalTests {
    @Test("The plugin answers within twelve seconds; approval and retry then fill from the grant")
    func pendingThenRetry() async throws {
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
            "Waiting for Josh's approval (asked at \(approvalTime(askedAt))); retry the login after he approves")
        #expect(fixture.deadlines.count == 3)
        #expect(Set(fixture.deadlines).count == 1)
        #expect(fixture.authorizer.calls == 1)
        let passwordRequest = try #require(fixture.requests.last)
        #expect(fixture.bridge.requestMatches(passwordRequest))
        let usernameRequest = try #require(fixture.requests.first(where: { $0.field == .username }))
        #expect(throws: CredentialTransferError.unavailable) {
            _ = try CredentialTransfer.read(requestID: usernameRequest.id)
        }

        fixture.authorizer.approve()
        for task in fixture.appTasks { await task.value }
        #expect(fixture.grants.contains(fixture.loginID))
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

@MainActor
private final class BrowserApprovalFixture {
    let loginID = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let authorizer = BrowserFakeAuthorizer()
    let grants = CredentialApprovalGrants()
    var requests: [AgentBridgeRequest] = []
    var deadlines: [Date] = []
    var appTasks: [Task<Void, Never>] = []
    private(set) lazy var bridge = AgentBridgeDirectory(rootURL: root)
    private(set) lazy var accessControl = CredentialAccessController(
        store: CredentialAccessPolicyStore(fileURL: root.appendingPathComponent("policies.json")))
    private lazy var processor = AgentCredentialReleaseProcessor(bridge: bridge, accessControl: accessControl,
        grants: grants, approvals: CredentialApprovalCoordinator(lockState: BrowserUnlockedSession()))
    private lazy var generation = MirrorGeneration(id: UUID(), previousGenerationID: nil,
        createdAt: Date(), sourceExportedAt: Date(), scope: .full, exporterIdentifier: "fixture",
        exporterDisplayName: "Fixture", items: [MirrorItem(id: loginID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "Synthetic browser login", origins: ["https://example.com"], credentials: [
                .password(userName: "synthetic@example.com", password: "synthetic-browser-password")
            ])], delta: MirrorDelta(), skippedCredentialCount: 0)

    func invoke() async throws -> [String: Any] {
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
                return try await AgentBridgeClient(bridge: self.bridge).send(request, waitUntil: deadline) { _ in
                    await self.startAppRequest(request)
                }
            })
        try output.fileHandleForWriting.close()
        return try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    }

    private func startAppRequest(_ request: AgentBridgeRequest) {
        appTasks.append(Task { @MainActor in
            defer { bridge.removeRequest(id: request.id) }
            do {
                let response = try await processor.release(request: request, generation: generation,
                    onProgress: { progress in
                        self.authorizer.requestedAt = progress.askedAt
                        do { try self.bridge.write(progress, id: request.id) }
                        catch { Issue.record(error) }
                    }, authorize: { try await self.authorizer.authorize($0, onPromptStarted: $1) }, copyNative: { _, _ in
                        Issue.record("Browser attempted native copy")
                    })
                try bridge.write(response)
            } catch let failure as AgentBridgeFailure {
                try? bridge.write(AgentBridgeResponse(id: request.id, ok: false, error: failure.code))
            } catch { Issue.record(error) }
        })
    }

    func cleanUp() {
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
