import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Credential retention")
struct CredentialRetentionTests {
    @Test("Ask, automatic and blocked rules control the same credential release", arguments: CredentialAccessPolicy.allCases)
    func policyControlsDelivery(policy: CredentialAccessPolicy) async throws {
        let fixture = try ReleaseFixture(policy: policy)
        defer { fixture.cleanUp() }
        var approvals = 0
        var nativeCopies = 0
        let request = fixture.request()
        try fixture.bridge.write(request)
        do {
            let response = try await fixture.processor.release(
                request: request, generation: fixture.generation,
                authorize: { approval in
                    approvals += 1
                    #expect(approval.expirationSeconds == nil)
                },
                copyNative: { _, _ in nativeCopies += 1 }
            )
            #expect(policy != .block)
            #expect(response.ok)
            #expect(response.clipboardExpiresAt == nil)
            #expect(approvals == (policy == .ask ? 1 : 0))
            #expect(try read(requestID: request.id) == Data(ReleaseFixture.password.utf8))
            #expect(try read(requestID: request.id) == Data(ReleaseFixture.password.utf8))
            CredentialTransfer.clear(requestID: request.id)
            #expect(throws: CredentialTransferError.unavailable) {
                _ = try read(requestID: request.id)
            }
        } catch let failure as AgentBridgeFailure {
            #expect(policy == .block)
            #expect(failure.code == .policyDenied)
            #expect(approvals == 0)
            #expect(throws: CredentialTransferError.unavailable) {
                _ = try read(requestID: request.id)
            }
        }
        #expect(nativeCopies == 0)
    }

    @Test("An expired or changed request after approval releases nothing", arguments: [false, true])
    func leaseEndsDuringApproval(replace: Bool) async throws {
        let fixture = try ReleaseFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let request = fixture.request()
        try fixture.bridge.write(request)
        var approvals = 0
        do {
            _ = try await fixture.processor.release(
                request: request, generation: fixture.generation,
                authorize: { _ in
                    approvals += 1
                    if replace {
                        try fixture.bridge.write(AgentBridgeRequest(
                            id: request.id, createdAt: request.createdAt,
                            action: .acquire, targetURL: "https://other.example",
                            field: .password
                        ))
                    } else {
                        fixture.bridge.removeRequest(id: request.id)
                    }
                },
                copyNative: { _, _ in Issue.record("Acquire attempted native paste") }
            )
            Issue.record("Expired request was released")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == .requestExpired)
        }
        #expect(approvals == 1)
        #expect(throws: CredentialTransferError.unavailable) {
            _ = try read(requestID: request.id)
        }
    }

    @Test("Refused approval does not release or retry")
    func denialDoesNotRetry() async throws {
        let fixture = try ReleaseFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let request = fixture.request()
        try fixture.bridge.write(request)
        var approvals = 0
        do {
            _ = try await fixture.processor.release(
                request: request, generation: fixture.generation,
                authorize: { _ in
                    approvals += 1
                    throw CredentialReleaseAuthorizationError.denied
                },
                copyNative: { _, _ in Issue.record("Acquire attempted native paste") }
            )
            Issue.record("Denied request was released")
        } catch CredentialReleaseAuthorizationError.denied {}
        #expect(approvals == 1)
        #expect(throws: CredentialTransferError.unavailable) {
            _ = try read(requestID: request.id)
        }
    }

    @Test("References are independent and clearing one leaves the other available")
    func independentReferences() throws {
        let first = UUID()
        let second = UUID()
        defer {
            CredentialTransfer.clear(requestID: first)
            CredentialTransfer.clear(requestID: second)
        }
        try CredentialTransfer.publish("first synthetic value", requestID: first)
        try CredentialTransfer.publish("second synthetic value", requestID: second)
        #expect(try read(requestID: first) == Data("first synthetic value".utf8))
        CredentialTransfer.clear(requestID: first)
        CredentialTransfer.clear(requestID: first)
        #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: first) }
        #expect(try read(requestID: second) == Data("second synthetic value".utf8))
    }

    private func read(requestID: UUID) throws -> Data {
        try CredentialTransfer.read(requestID: requestID)
    }
}

@MainActor
private struct ReleaseFixture {
    static let password = "synthetic-credential-value"
    let bridge: AgentBridgeDirectory
    let generation: MirrorGeneration
    let processor: AgentCredentialReleaseProcessor

    init(policy: CredentialAccessPolicy) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-retrieval-test-\(UUID().uuidString)")
        bridge = AgentBridgeDirectory(rootURL: root)
        try bridge.prepare()
        let credentialID = UUID()
        let policyURL = root.appendingPathComponent("policies.json")
        let contents: [String: Any] = [
            "version": 1,
            "records": [["credentialID": credentialID.uuidString, "policy": policy.rawValue]],
        ]
        try JSONSerialization.data(withJSONObject: contents).write(to: policyURL)
        let accessControl = CredentialAccessController(store: CredentialAccessPolicyStore(fileURL: policyURL))
        processor = AgentCredentialReleaseProcessor(bridge: bridge, accessControl: accessControl)
        let item = MirrorItem(
            id: credentialID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "Synthetic login", origins: ["https://example.com"],
            credentials: [.password(userName: "synthetic@example.com", password: Self.password)]
        )
        generation = MirrorGeneration(
            id: UUID(), previousGenerationID: nil, createdAt: Date(), sourceExportedAt: Date(),
            scope: .full, exporterIdentifier: "fixture", exporterDisplayName: "Fixture",
            items: [item], delta: MirrorDelta(), skippedCredentialCount: 0
        )
    }

    func request() -> AgentBridgeRequest {
        AgentBridgeRequest(action: .acquire, targetURL: "https://example.com/login", field: .password)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: bridge.rootURL)
    }
}
