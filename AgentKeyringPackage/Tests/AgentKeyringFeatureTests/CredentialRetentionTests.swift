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

    @Test("One login approval covers later fields and End all grants asks again")
    func loginGrant() async throws {
        let fixture = try ReleaseFixture(policy: .ask, includeCode: true)
        defer { fixture.cleanUp() }
        var approvals = 0
        for field in [AgentCredentialField.password, .username, .totp, .password] {
            let request = fixture.request(field: field)
            try fixture.bridge.write(request)
            let response = try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _ in approvals += 1 }, copyNative: { _, _ in })
            #expect(response.ok)
            CredentialTransfer.clear(requestID: request.id)
        }
        #expect(approvals == 1)
        fixture.grants.endAll()
        let retry = fixture.request()
        defer { CredentialTransfer.clear(requestID: retry.id) }
        try fixture.bridge.write(retry)
        _ = try await fixture.processor.release(request: retry, generation: fixture.generation,
            authorize: { _ in approvals += 1 }, copyNative: { _, _ in })
        #expect(approvals == 2)
    }

    @Test("Blocked policy releases nothing even with an active grant")
    func blockedGrant() async throws {
        let fixture = try ReleaseFixture(policy: .block)
        defer { fixture.cleanUp() }
        fixture.grants.approve(fixture.generation.items[0].id)
        let request = fixture.request()
        try fixture.bridge.write(request)
        do {
            _ = try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _ in Issue.record("Blocked login prompted") }, copyNative: { _, _ in })
            Issue.record("Blocked login released")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .policyDenied) }
        #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: request.id) }
    }

    @Test("A dead caller and the old two-minute limit do not end a request")
    func appOwnsRequest() async throws {
        let fixture = try ReleaseFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let request = AgentBridgeRequest(createdAt: Date().addingTimeInterval(-121),
            callerPID: -1, action: .acquire, targetURL: "https://example.com", field: .password)
        defer { CredentialTransfer.clear(requestID: request.id) }
        try fixture.bridge.write(request)
        let response = try await fixture.processor.release(request: request, generation: fixture.generation,
            authorize: { approval in #expect(approval.authorizationDeadline == request.expiresAt) },
            copyNative: { _, _ in Issue.record("Unexpected copy") })
        #expect(response.ok)
    }

    @Test("An unanswered request expires after ten minutes without prompting")
    func expiredRequest() async throws {
        let fixture = try ReleaseFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let request = AgentBridgeRequest(createdAt: Date().addingTimeInterval(-601),
            action: .acquire, targetURL: "https://example.com", field: .password)
        try fixture.bridge.write(request)
        do {
            _ = try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _ in Issue.record("Expired request prompted") }, copyNative: { _, _ in })
            Issue.record("Expired request released")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .requestExpired) }
        #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: request.id) }
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
        try CredentialTransfer.publish("first synthetic value", requestID: first, credentialID: UUID(), expiresAfter: 300)
        try CredentialTransfer.publish("second synthetic value", requestID: second, credentialID: UUID(), expiresAfter: 300)
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
        try CredentialTransfer.publish("initial synthetic code", requestID: reference, credentialID: UUID(), expiresAfter: 300,
            codeRecord: .totp(secret: seed, period: 30, digits: 8,
                userName: "code-account", algorithm: .sha1, issuer: nil))
        let channel = NSPasteboard(name: .init("com.agentkeyring.credential.\(reference.uuidString)"))
        for type in channel.types ?? [] {
            #expect(channel.data(forType: type)?.range(of: seed) == nil)
        }
        CredentialTransfer.refreshRetainedValues(now: Date(timeIntervalSince1970: 59))
        #expect(try CredentialTransfer.read(requestID: reference) == Data("94287082".utf8))
        CredentialTransfer.refreshRetainedValues(now: Date(timeIntervalSince1970: 60))
        #expect(try CredentialTransfer.read(requestID: reference) == Data("37359152".utf8))
    }

    @Test("Retained values expire after five minutes")
    func defaultExpiry() throws {
        let reference = UUID()
        let publishedAt = Date()
        defer { CredentialTransfer.clear(requestID: reference) }
        try CredentialTransfer.publish("synthetic", requestID: reference, credentialID: UUID(), expiresAfter: 300)
        #expect(try CredentialTransfer.read(requestID: reference, now: publishedAt.addingTimeInterval(299)) == Data("synthetic".utf8))
        #expect(throws: CredentialTransferError.unavailable) {
            _ = try CredentialTransfer.read(requestID: reference, now: publishedAt.addingTimeInterval(301))
        }
    }

    @Test("The app clears an expired buffer without a read")
    func unattendedExpiry() async throws {
        let reference = UUID()
        defer { CredentialTransfer.clear(requestID: reference) }
        try CredentialTransfer.publish("synthetic", requestID: reference, credentialID: UUID(), expiresAfter: 0.05)
        try await Task.sleep(for: .milliseconds(600))
        // Reading with an earlier clock proves cleanup removed the bytes independently.
        #expect(throws: CredentialTransferError.unavailable) {
            _ = try CredentialTransfer.read(requestID: reference, now: Date(timeIntervalSince1970: 0))
        }
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
        try CredentialTransfer.publish("unrelated", requestID: unrelated, credentialID: UUID(), expiresAfter: 300)
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
        CredentialTransfer.refreshRetainedValues(now: Date(timeIntervalSince1970: 59))
        #expect(try CredentialTransfer.read(requestID: request.id) == Data("94287082".utf8))
        CredentialTransfer.refreshRetainedValues(now: Date(timeIntervalSince1970: 60))
        #expect(try CredentialTransfer.read(requestID: request.id) == Data("37359152".utf8))
    }

    @Test("An invalid code record fails at acquisition without publishing a buffer")
    func invalidCodeAtAcquisition() async throws {
        let fixture = try ReleaseFixture(policy: .allowAutomatically, codeOnly: true, codeSeed: Data())
        defer { fixture.cleanUp() }
        let request = fixture.request(field: .totp)
        try fixture.bridge.write(request)
        await #expect(throws: CredentialResolverError.invalidTOTP) {
            try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _ in }, copyNative: { _, _ in })
        }
        #expect(throws: CredentialTransferError.unavailable) { _ = try read(requestID: request.id) }
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
    let grants = CredentialApprovalGrants()

    init(policy: CredentialAccessPolicy, codeOnly: Bool = false, includeCode: Bool = false, codeSeed: Data = Data("12345678901234567890".utf8)) throws {
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
        processor = AgentCredentialReleaseProcessor(bridge: bridge, accessControl: accessControl, grants: grants)
        let item = MirrorItem(
            id: credentialID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
            title: "Synthetic login", origins: ["https://example.com"],
            credentials: codeOnly ? [.totp(secret: codeSeed,
                period: 30, digits: 8, userName: "synthetic@example.com", algorithm: .sha1, issuer: nil)]
                : [.password(userName: "synthetic@example.com", password: Self.password)]
                    + (includeCode ? [.totp(secret: codeSeed, period: 30, digits: 8,
                        userName: "synthetic@example.com", algorithm: .sha1, issuer: nil)] : [])
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
