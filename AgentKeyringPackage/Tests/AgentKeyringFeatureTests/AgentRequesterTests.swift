import AgentKeyringTestSupport
import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Requester signatures")
struct AgentRequesterSignatureTests {
    @Test("Apple-signed code verifies its designated requirement, but cannot impersonate Claude")
    func signedBinary() throws {
        let binary = URL(fileURLWithPath: "/usr/bin/true")
        let identity = try #require(RequesterCodeSignature.verify(executableURL: binary))
        #expect(identity.signer == "Apple")
        #expect(identity.teamIdentifier == nil)
        #expect(RequesterCodeSignature.verify(executableURL: binary, name: "Claude Code") == nil)
    }

    @Test("A live Apple-signed process verifies through SecCode")
    func signedProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        #expect(RequesterCodeSignature.verify(processIdentifier: process.processIdentifier, name: "sleep")?.signer == "Apple")
    }

    @Test("Ad hoc binaries and unsigned scripts stay unverified")
    func unsignedFixtures() throws {
        let root = URL(fileURLWithPath: "/tmp/ak-signatures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("agent.c")
        let binary = root.appendingPathComponent("claude")
        let script = root.appendingPathComponent("pi")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try run("/usr/bin/clang", [source.path, "-o", binary.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        #expect(RequesterCodeSignature.verify(executableURL: binary, name: "Claude Code") == nil)
        #expect(RequesterCodeSignature.verify(executableURL: script, name: "pi") == nil)
    }

    @Test("Verification stops at a script runtime below a signed agent")
    func interpreterBoundary() throws {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/bin/zsh", 101), 101: ("/usr/bin/python3", 102), 102: ("/opt/bin/codex", 1),
        ]
        let ancestor = try #require(AgentDisplayLabel.firstAgentAncestor(startingPID: 100,
            skipInterpreters: false, processInfo: { tree[$0] }))
        #expect(ancestor.processIdentifier == 101)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@MainActor
@Suite("Requester approval boundaries")
struct AgentRequesterPolicyTests {
    private let unverified = AgentRequester(name: "Claude Code", verifiedIdentity: nil, processIdentifier: 0,
        context: ApprovalRequesterContext(machineName: "Fixture Mac", workingDirectory: "/tmp", networkAddress: nil))

    @Test("Automatic release needs explicit approval on every unverified request", arguments: [AgentCredentialField.password, .username],
        [CredentialAccessPolicy.allowAutomatically, .ask])
    func unverifiedAlwaysAsks(field: AgentCredentialField, policy: CredentialAccessPolicy) async throws {
        let fixture = try FillTestFixture(policy: policy,
            filler: FakeCredentialFiller(inspection: fillInspection(focusedSubrole: field == .password ? "AXSecureTextField" : nil)))
        defer { fixture.cleanUp() }
        fixture.grants.approve(fixture.generation.items[0].id, action: .fill,
            requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "example.com", account: "fixture")
        var approvals = 0
        for _ in 0..<2 {
            let response = try await fixture.processor.release(request: fixture.request(field: field), requester: unverified,
                generation: fixture.generation, authorize: { _, started in approvals += 1; started() })
            #expect(response.ok)
        }
        #expect(approvals == 2)
        #expect(fixture.grants.active.count == 1) // Only the pre-existing verified grant.
        #expect(fixture.filler.typedValues.count == 2)
        #expect(unverified.displayLabel == "Claude Code, unverified")
    }

    @Test("Declining an unverified automatic request releases nothing")
    func unverifiedDenied() async throws {
        let fixture = try FillTestFixture(policy: .allowAutomatically)
        defer { fixture.cleanUp() }
        await #expect(throws: CredentialReleaseAuthorizationError.denied) {
            try await fixture.processor.release(request: fixture.request(), requester: unverified, generation: fixture.generation,
                authorize: { _, _ in throw CredentialReleaseAuthorizationError.denied })
        }
        #expect(fixture.filler.typedValues.isEmpty)
        #expect(fixture.grants.active.isEmpty)
    }

    @Test("One verified agent's approval never covers another's grant")
    func grantsStayWithRequester() async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let other = AgentRequester(name: "Another agent", verifiedIdentity: VerifiedRequesterIdentity(
            signingIdentifier: "test.fixture.other", teamIdentifier: "FIXTURE", signer: "Fixture"), processIdentifier: 0,
            context: syntheticVerifiedRequester.context)
        var prompts = 0
        for requester in [syntheticVerifiedRequester, other, syntheticVerifiedRequester, other] {
            _ = try await fixture.processor.release(request: fixture.request(), requester: requester, generation: fixture.generation,
                authorize: { _, started in prompts += 1; started() })
        }
        #expect(prompts == 2)
        #expect(fixture.grants.active.count == 2)
    }

    @Test("Concurrent identities have separate prompts", arguments: [true, false])
    func pendingIdentitiesStaySeparate(verified: Bool) async throws {
        let coordinator = CredentialApprovalCoordinator(lockState: RequesterUnlockedSession())
        let login = UUID()
        let firstIdentity = verified ? syntheticVerifiedRequester.verifiedIdentity : nil
        let secondIdentity = verified ? VerifiedRequesterIdentity(signingIdentifier: "other", teamIdentifier: "FIXTURE", signer: "Fixture") : nil
        var firstPrompt: CheckedContinuation<Void, Never>?
        var prompts = 0
        let first = Task {
            try await coordinator.authorize(credentialID: login, requesterIdentity: firstIdentity,
                authorizationDeadline: Date().addingTimeInterval(60), approvalRequest: approvalRequest()) { started in
                    prompts += 1; started()
                    await withCheckedContinuation { firstPrompt = $0 }
                }
        }
        while firstPrompt == nil { await Task.yield() }
        let second = Task {
            try await coordinator.authorize(credentialID: login, requesterIdentity: secondIdentity,
                authorizationDeadline: Date().addingTimeInterval(60), approvalRequest: approvalRequest()) { started in
                    prompts += 1; started()
                }
        }
        for _ in 0..<20 { await Task.yield() }
        firstPrompt?.resume()
        try await first.value
        try await second.value
        #expect(prompts == 2)
    }

    @Test("Machine context survives CloudKit and is covered by the phone signature")
    func signedMachineContext() throws {
        let request = try ApprovalRequest(agentDisplayLabel: syntheticVerifiedRequester.displayLabel, site: "example.com",
            account: "fixture", field: .password, action: .fill, requesterContext: syntheticVerifiedRequester.context)
        let fields = try #require(ApprovalCloudRecords.signedFields(from: ApprovalCloudRecords.request(request)))
        #expect(fields == request.signedFields)
        #expect(fields.notificationBody.contains("Fixture Mac"))
        let changed = ApprovalSignedFields(requestID: fields.requestID, agentDisplayLabel: fields.agentDisplayLabel,
            site: fields.site, account: fields.account, field: fields.field, action: fields.action,
            oneTimeValue: fields.oneTimeValue, expiresAt: fields.expiresAt,
            requesterContext: ApprovalRequesterContext(machineName: "Another Mac", workingDirectory: "/tmp", networkAddress: "192.0.2.1"))
        #expect(fields.canonicalBytes(for: .approve) != changed.canonicalBytes(for: .approve))
    }

    private func approvalRequest() throws -> ApprovalRequest {
        try ApprovalRequest(agentDisplayLabel: "Fixture", site: "example.com", account: "fixture", field: .password, action: .fill)
    }
}

private struct RequesterUnlockedSession: CredentialSessionLockState { var isLocked: Bool { false } }
