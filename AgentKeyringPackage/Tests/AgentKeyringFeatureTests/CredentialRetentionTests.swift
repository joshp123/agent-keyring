import AppKit
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
        #expect(CredentialTransfer.clear(requestID: first))
        #expect(CredentialTransfer.clear(requestID: first))
        #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: first) }
        #expect(try read(requestID: second) == Data("second synthetic value".utf8))
    }

    @Test("Code retries generate a fresh code across the period boundary")
    func freshCodeOnRead() throws {
        let reference = UUID()
        defer { CredentialTransfer.clear(requestID: reference) }
        let seed = Data("12345678901234567890".utf8)
        try CredentialTransfer.publishCode(.totp(secret: seed, period: 30, digits: 8,
            userName: "code-account", algorithm: .sha1, issuer: nil), requestID: reference)
        #expect(try CredentialTransfer.read(requestID: reference, now: Date(timeIntervalSince1970: 59)) == Data("94287082".utf8))
        #expect(try CredentialTransfer.read(requestID: reference, now: Date(timeIntervalSince1970: 60)) == Data("37359152".utf8))
    }

    @Test("Retained values expire after five minutes by default")
    func defaultExpiry() throws {
        let reference = UUID()
        let publishedAt = Date()
        defer { CredentialTransfer.clear(requestID: reference) }
        try CredentialTransfer.publish("synthetic", requestID: reference)
        #expect(try CredentialTransfer.read(requestID: reference, now: publishedAt.addingTimeInterval(299)) == Data("synthetic".utf8))
        #expect(throws: CredentialTransferError.unavailable) {
            _ = try CredentialTransfer.read(requestID: reference, now: publishedAt.addingTimeInterval(301))
        }
    }

    @Test("The app clears an expired buffer without a read")
    func unattendedExpiry() async throws {
        let reference = UUID()
        defer { CredentialTransfer.clear(requestID: reference) }
        try CredentialTransfer.publish("synthetic", requestID: reference, expiresAfter: 0.05)
        try await Task.sleep(for: .milliseconds(600))
        // Reading with an earlier clock proves cleanup removed the bytes independently.
        #expect(throws: CredentialTransferError.unavailable) {
            _ = try CredentialTransfer.read(requestID: reference, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test("The app clears a buffer when its requester exits")
    func requesterExit() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.2"]
        try process.run()
        let reference = UUID()
        defer { CredentialTransfer.clear(requestID: reference) }
        try CredentialTransfer.publish("synthetic", requestID: reference, requesterPID: process.processIdentifier)
        #expect(try read(requestID: reference) == Data("synthetic".utf8))
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(600))
        let channel = NSPasteboard(name: .init("com.agentkeyring.credential.\(reference.uuidString)"))
        #expect(channel.data(forType: .init("com.agentkeyring.credential")) == nil)
        #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: reference) }
    }

    @Test("Blocking during approval prevents release")
    func blockedDuringApproval() async throws {
        let fixture = try ReleaseFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let request = fixture.request()
        try fixture.bridge.write(request)
        do {
            _ = try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _ in
                    await fixture.accessControl.setPolicy(.block, for: [fixture.generation.items[0].id])
                }, copyNative: { _, _ in Issue.record("Unexpected copy") })
            Issue.record("Blocked login released")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == .policyDenied)
        }
        #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: request.id) }
    }

    @Test("Blocking a login revokes all its buffers and preserves other logins")
    func blockingRevokesBuffers() async throws {
        let fixture = try ReleaseFixture(policy: .allowAutomatically)
        defer { fixture.cleanUp() }
        let first = fixture.request()
        let second = fixture.request()
        let unrelated = UUID()
        defer {
            CredentialTransfer.clear(requestID: first.id)
            CredentialTransfer.clear(requestID: second.id)
            CredentialTransfer.clear(requestID: unrelated)
        }
        for request in [first, second] {
            try fixture.bridge.write(request)
            _ = try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _ in Issue.record("Unexpected approval") }, copyNative: { _, _ in })
        }
        try CredentialTransfer.publish("unrelated", requestID: unrelated, credentialID: UUID())
        await fixture.accessControl.setPolicy(.block, for: [fixture.generation.items[0].id])
        for request in [first, second] {
            #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: request.id) }
        }
        #expect(try read(requestID: unrelated) == Data("unrelated".utf8))
    }

    @Test("Acquiring a code-only login approves once and supports fresh retry reads")
    func acquireCodeOnlyLogin() async throws {
        let fixture = try ReleaseFixture(policy: .ask, codeOnly: true)
        defer { fixture.cleanUp() }
        let request = fixture.request(field: .totp)
        defer { CredentialTransfer.clear(requestID: request.id) }
        try fixture.bridge.write(request)
        var approvals = 0
        let response = try await fixture.processor.release(request: request, generation: fixture.generation,
            authorize: { approval in
                approvals += 1
                #expect(approval.account == "synthetic@example.com")
            }, copyNative: { _, _ in Issue.record("Unexpected native copy") })
        #expect(response.ok)
        #expect(approvals == 1)
        #expect(try CredentialTransfer.read(requestID: request.id, now: Date(timeIntervalSince1970: 59)) == Data("94287082".utf8))
        #expect(try CredentialTransfer.read(requestID: request.id, now: Date(timeIntervalSince1970: 60)) == Data("37359152".utf8))
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
    let accessControl: CredentialAccessController

    init(policy: CredentialAccessPolicy, codeOnly: Bool = false) throws {
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
        accessControl = CredentialAccessController(store: CredentialAccessPolicyStore(fileURL: policyURL))
        processor = AgentCredentialReleaseProcessor(bridge: bridge, accessControl: accessControl)
        let item = MirrorItem(
            id: credentialID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "Synthetic login", origins: ["https://example.com"],
            credentials: codeOnly ? [.totp(secret: Data("12345678901234567890".utf8),
                period: 30, digits: 8, userName: "synthetic@example.com", algorithm: .sha1, issuer: nil)]
                : [.password(userName: "synthetic@example.com", password: Self.password)]
        )
        generation = MirrorGeneration(
            id: UUID(), previousGenerationID: nil, createdAt: Date(), sourceExportedAt: Date(),
            scope: .full, exporterIdentifier: "fixture", exporterDisplayName: "Fixture",
            items: [item], delta: MirrorDelta(), skippedCredentialCount: 0
        )
    }

    func request(field: AgentCredentialField = .password) -> AgentBridgeRequest {
        AgentBridgeRequest(action: .acquire, targetURL: "https://example.com/login", field: field)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: bridge.rootURL)
    }
}
