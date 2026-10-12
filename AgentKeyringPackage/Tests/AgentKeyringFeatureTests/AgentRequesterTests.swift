import AgentKeyringTestSupport
import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Harness attribution")
struct AgentRequesterAttributionTests {
    @Test("The socket peer's ancestry supplies the harness, session and folder", arguments: ["claude", "codex"])
    func harnessAncestor(executable: String) throws {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/opt/bin/agent-keyring", 101), 101: ("/bin/zsh", 102),
            102: ("/usr/bin/python3", 103), 103: ("/opt/bin/\(executable)", 1),
        ]
        let start = HarnessProcessStartTime(seconds: 1_000, microseconds: 123)
        let requester = AgentRequester.attribution(peerProcessIdentifier: 100, processInfo: { tree[$0] },
            startTime: { pid in #expect(pid == 103); return start },
            folder: { pid in #expect(pid == 103); return "/fixture/project" })
        #expect(requester.name == (executable == "claude" ? "Claude Code" : "Codex"))
        #expect(requester.displayLabel == requester.name)
        #expect(requester.session == HarnessSession(processIdentifier: 103, processStartTime: start))
        #expect(requester.workingDirectory == "/fixture/project")
    }

    @Test("A process that changes during attribution cannot receive a reusable session grant")
    func unstableProcess() {
        var reads = 0
        let requester = AgentRequester.attribution(peerProcessIdentifier: 100,
            processInfo: { _ in ("/opt/bin/claude", 1) }, startTime: { _ in
                reads += 1
                return HarnessProcessStartTime(seconds: UInt64(reads), microseconds: 0)
            }, folder: { _ in "/fixture" })
        #expect(requester.session == nil)
    }

    @Test("Phone records contain signed harness attribution, with host details only in activity", arguments: ["pid", "seconds", "microseconds", "folder"])
    func signedAttribution(changedField: String) throws {
        let request = try ApprovalRequest(agentDisplayLabel: syntheticRequester.displayLabel, site: "example.com",
            account: "fixture", field: .password, action: .fill, requesterContext: syntheticRequester.approvalContext)
        let record = ApprovalCloudRecords.request(request)
        let fields = try #require(ApprovalCloudRecords.signedFields(from: record))
        #expect(fields == request.signedFields)
        #expect(fields.notificationTitle.contains("Fixture agent"))
        #expect(fields.notificationBody.contains("/tmp"))
        #expect(!fields.notificationBody.contains(syntheticRequester.machineName))
        #expect(!fields.notificationBody.contains(syntheticRequester.networkAddress!))
        #expect(record.encryptedValues["machineName"] == nil && record.encryptedValues["networkAddress"] == nil)
        let session = try #require(syntheticRequester.session)
        let changedSession = HarnessSession(processIdentifier: session.processIdentifier + (changedField == "pid" ? 1 : 0),
            processStartTime: HarnessProcessStartTime(seconds: session.processStartTime.seconds + (changedField == "seconds" ? 1 : 0),
                microseconds: session.processStartTime.microseconds + (changedField == "microseconds" ? 1 : 0)))
        let changed = ApprovalSignedFields(requestID: fields.requestID, agentDisplayLabel: fields.agentDisplayLabel,
            site: fields.site, account: fields.account, field: fields.field, action: fields.action,
            oneTimeValue: fields.oneTimeValue, expiresAt: fields.expiresAt,
            requesterContext: ApprovalRequesterContext(session: changedSession,
                workingDirectory: changedField == "folder" ? "/elsewhere" : "/tmp"))
        #expect(fields.canonicalBytes(for: .approve) != changed.canonicalBytes(for: .approve))
        let activity = AgentRequestActivity(requestID: request.id, action: .fill, requester: syntheticRequester,
            completedAt: Date(), succeeded: true, error: nil)
        #expect(activity.requester.machineName == "Fixture Mac")
        #expect(activity.requester.networkAddress == "192.0.2.1")
    }
}

@MainActor
@Suite("Harness session approval boundaries")
struct AgentRequesterPolicyTests {
    @Test("Allow automatically releases without a prompt, including unavailable session attribution", arguments: [AgentCredentialField.password, .username], [true, false])
    func automaticRelease(field: AgentCredentialField, knownSession: Bool) async throws {
        let fixture = try FillTestFixture(policy: .allowAutomatically,
            filler: FakeCredentialFiller(inspection: fillInspection(focusedSubrole: field == .password ? "AXSecureTextField" : nil)))
        defer { fixture.cleanUp() }
        let requester = knownSession ? syntheticRequester : requesterWithoutStartTime()
        let response = try await fixture.processor.release(request: fixture.request(field: field), requester: requester,
            generation: fixture.generation, authorize: { _, _ in Issue.record("Automatic release prompted") })
        #expect(response.ok && fixture.filler.typedValues.count == 1)
        #expect(fixture.grants.active.isEmpty)
    }

    @Test("The same harness name does not share grants between sessions or reused PIDs", arguments: ["pid", "seconds", "microseconds"])
    func grantsStayWithSession(changedField: String) async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let other = anotherSession(changedField: changedField)
        var prompts = 0
        for requester in [syntheticRequester, other, syntheticRequester, other] {
            let response = try await fixture.processor.release(request: fixture.request(), requester: requester,
                generation: fixture.generation, authorize: { _, started in prompts += 1; started() })
            #expect(response.ok)
        }
        #expect(prompts == 2 && fixture.grants.active.count == 2)
        #expect(fixture.filler.typedValues.count == 4)
    }

    @Test("Ask without a process start time requires approval for each request")
    func unknownSessionAsks() async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        var prompts = 0
        for _ in 0..<2 {
            _ = try await fixture.processor.release(request: fixture.request(), requester: requesterWithoutStartTime(),
                generation: fixture.generation, authorize: { _, started in prompts += 1; started() })
        }
        #expect(prompts == 2 && fixture.grants.active.isEmpty)
    }

    @Test("Different sessions join a pending approval for the same login")
    func differentSessionsJoin() async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let coordinator = CredentialApprovalCoordinator(lockState: RequesterUnlockedSession())
        let processor = processor(fixture, coordinator: coordinator)
        var finish: CheckedContinuation<Void, Never>?
        var prompts = 0
        let first = Task {
            try await processor.release(request: fixture.request(), requester: syntheticRequester, generation: fixture.generation,
                authorize: { _, started in
                    prompts += 1; started()
                    await withCheckedContinuation { finish = $0 }
                })
        }
        try await requesterEventually { finish != nil }
        var joined = false
        let second = Task {
            try await processor.release(request: fixture.request(), requester: anotherSession(changedField: "pid"),
                generation: fixture.generation, onProgress: { _ in joined = true },
                authorize: { _, _ in Issue.record("Joined session prompted separately") })
        }
        try await requesterEventually { joined }
        #expect(prompts == 1 && fixture.filler.typedValues.isEmpty)
        finish?.resume()
        #expect(try await first.value.ok)
        #expect(try await second.value.ok)
        #expect(fixture.grants.active.count == 2 && fixture.filler.typedValues.count == 2)
    }

    @Test("A session queues in order and reuses the grant when each request's turn begins")
    func sessionQueue() async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let coordinator = CredentialApprovalCoordinator(lockState: RequesterUnlockedSession())
        let processor = processor(fixture, coordinator: coordinator)
        let session = try #require(syntheticRequester.session)
        var finish: CheckedContinuation<Void, Never>?
        var prompts = 0
        var completionOrder: [Int] = []
        let first = Task {
            let response = try await processor.release(request: fixture.request(), requester: syntheticRequester,
                generation: fixture.generation, authorize: { _, started in
                    prompts += 1; started()
                    await withCheckedContinuation { finish = $0 }
                })
            completionOrder.append(1)
            return response
        }
        try await requesterEventually { finish != nil }
        let second = Task {
            let response = try await processor.release(request: fixture.request(), requester: syntheticRequester,
                generation: fixture.generation, authorize: { _, _ in Issue.record("Queued request missed the new grant") })
            completionOrder.append(2)
            return response
        }
        try await requesterEventually { coordinator.sessionRequests.waitingCount(for: session) == 1 }
        let third = Task {
            let response = try await processor.release(request: fixture.request(), requester: syntheticRequester,
                generation: fixture.generation, authorize: { _, _ in Issue.record("Queued request missed the new grant") })
            completionOrder.append(3)
            return response
        }
        try await requesterEventually { coordinator.sessionRequests.waitingCount(for: session) == 2 }
        #expect(fixture.filler.inspectCount == 1 && fixture.filler.typedValues.isEmpty)
        finish?.resume()
        #expect(try await first.value.ok)
        #expect(try await second.value.ok)
        #expect(try await third.value.ok)
        #expect(completionOrder == [1, 2, 3])
        #expect(prompts == 1)
        #expect(fixture.filler.typedValues.count == 3)
    }

    @Test("A denied request frees the session for its next approval")
    func denialUnblocksQueue() async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let coordinator = CredentialApprovalCoordinator(lockState: RequesterUnlockedSession())
        let processor = processor(fixture, coordinator: coordinator)
        var finish: CheckedContinuation<Void, Never>?
        let first = Task {
            try await processor.release(request: fixture.request(), requester: syntheticRequester, generation: fixture.generation,
                authorize: { _, started in
                    started()
                    await withCheckedContinuation { finish = $0 }
                    throw CredentialReleaseAuthorizationError.denied
                })
        }
        try await requesterEventually { finish != nil }
        var prompted = false
        let second = Task {
            try await processor.release(request: fixture.request(), requester: syntheticRequester, generation: fixture.generation,
                authorize: { _, started in prompted = true; started() })
        }
        try await requesterEventually { coordinator.sessionRequests.waitingCount(for: syntheticRequester.session!) == 1 }
        #expect(!prompted)
        finish?.resume()
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await first.value }
        #expect(try await second.value.ok)
        #expect(prompted && fixture.filler.typedValues.count == 1)
    }

    @Test("Cancelled and expired queued requests never prompt or release", arguments: [true, false])
    func abandonQueuedRequest(cancel: Bool) async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let coordinator = CredentialApprovalCoordinator(lockState: RequesterUnlockedSession())
        let processor = processor(fixture, coordinator: coordinator)
        var finish: CheckedContinuation<Void, Never>?
        let first = Task {
            try await processor.release(request: fixture.request(), requester: syntheticRequester, generation: fixture.generation,
                authorize: { _, started in started(); await withCheckedContinuation { finish = $0 } })
        }
        try await requesterEventually { finish != nil }
        let request = AgentBridgeRequest(createdAt: Date().addingTimeInterval(cancel ? 0 : -599.7),
            action: .fill, targetURL: "https://example.com", field: .password)
        let second = Task {
            try await processor.release(request: request, requester: syntheticRequester, generation: fixture.generation,
                authorize: { _, _ in Issue.record("Abandoned queued request prompted") })
        }
        try await requesterEventually { coordinator.sessionRequests.waitingCount(for: syntheticRequester.session!) == 1 }
        if cancel {
            second.cancel()
            await #expect(throws: CancellationError.self) { try await second.value }
        } else {
            await #expect(throws: CredentialReleaseAuthorizationError.expired) { try await second.value }
        }
        #expect(coordinator.sessionRequests.waitingCount(for: syntheticRequester.session!) == 0)
        #expect(fixture.filler.inspectCount == 1 && fixture.filler.typedValues.isEmpty)
        finish?.resume()
        #expect(try await first.value.ok)
        #expect(fixture.filler.typedValues.count == 1)
    }

    private func processor(_ fixture: FillTestFixture, coordinator: CredentialApprovalCoordinator) -> AgentCredentialReleaseProcessor {
        AgentCredentialReleaseProcessor(accessControl: fixture.accessControl, grants: fixture.grants,
            approvals: coordinator, filler: fixture.filler)
    }

    private func anotherSession(changedField: String) -> AgentRequester {
        let start = syntheticRequester.processStartTime!
        return AgentRequester(name: syntheticRequester.name,
            processIdentifier: syntheticRequester.processIdentifier + (changedField == "pid" ? 1 : 0),
            processStartTime: HarnessProcessStartTime(seconds: start.seconds + (changedField == "seconds" ? 1 : 0),
                microseconds: start.microseconds + (changedField == "microseconds" ? 1 : 0)),
            workingDirectory: syntheticRequester.workingDirectory, machineName: syntheticRequester.machineName,
            networkAddress: syntheticRequester.networkAddress)
    }

    private func requesterWithoutStartTime() -> AgentRequester {
        AgentRequester(name: "Claude Code", processIdentifier: 100, processStartTime: nil,
            workingDirectory: "/tmp", machineName: "Fixture Mac", networkAddress: nil)
    }
}

@MainActor
private func requesterEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition())
}

private struct RequesterUnlockedSession: CredentialSessionLockState { var isLocked: Bool { false } }
