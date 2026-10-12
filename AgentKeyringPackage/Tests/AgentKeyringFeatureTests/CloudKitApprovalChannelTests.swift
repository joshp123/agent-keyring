import AgentKeyringTestSupport
import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("CloudKit approval channel")
struct CloudKitApprovalChannelTests {
    @Test("Requests preserve signed fields and keep login and notification text encrypted", arguments: AgentCredentialField.allCases)
    func requestShape(field: AgentCredentialField) async throws {
        let request = try ApprovalRequest(agentDisplayLabel: "Test agent", site: "example.com", account: "synthetic",
            field: field, action: .fill, createdAt: Date(timeIntervalSince1970: 1_000))
        let database = InMemoryApprovalCloudDatabase()
        try await database.save(ApprovalCloudRecords.request(request))
        let record = try #require(try await database.fetch(ApprovalCloudRecords.requestID(request.id)))
        #expect(record.recordType == "ApprovalRequest")
        #expect(record.recordID.recordName == request.id.uuidString)
        #expect(record.recordID.zoneID == ApprovalCloudRecords.requestZone)
        #expect(record["agentDisplayLabel"] as? String == request.agentDisplayLabel)
        #expect(record["field"] as? String == field.rawValue)
        #expect(record["action"] as? String == "fill")
        #expect(record["oneTimeValue"] as? Data == request.oneTimeValue)
        #expect((record["expiresAt"] as? NSNumber)?.int64Value == 1_600)
        #expect(record["site"] == nil)
        #expect(record["account"] == nil)
        #expect(record["notificationBody"] == nil)
        #expect(record.encryptedValues["site"] as? String == request.site)
        #expect(record.encryptedValues["account"] as? String == request.account)
        #expect(record.encryptedValues["notificationBody"] as? String ==
            "Test agent wants to fill \(field.rawValue) for synthetic on example.com.")
        #expect(record["notificationTitle"] as? String == "Login approval")
        #expect(record["notificationCategory"] as? String == "AGENT_KEYRING_APPROVAL")
        #expect(record["notificationInterruptionLevel"] as? String == "timeSensitive")
        #expect(Set(record.allKeys()) == ["agentDisplayLabel", "field", "action", "oneTimeValue", "expiresAt",
            "notificationTitle", "notificationCategory", "notificationInterruptionLevel", "site", "account", "notificationBody"])
        #expect(Set(record.encryptedValues.allKeys()) == ["site", "account", "notificationBody"])
    }

    @Test("Decisions use the same request name in their own zone and preserve signed bytes", arguments: ApprovalChoice.allCases)
    func decisionShape(choice: ApprovalChoice) async throws {
        let fixture = try CloudApprovalFixture()
        let decision = try fixture.decision(choice)
        let record = ApprovalCloudRecords.decision(decision)
        try await fixture.database.save(ApprovalCloudRecords.request(fixture.request))
        try await fixture.database.save(record)
        #expect(fixture.database.records.count == 2)
        #expect(record.recordType == "ApprovalDecision")
        #expect(record.recordID.recordName == fixture.request.id.uuidString)
        #expect(record.recordID.zoneID == ApprovalCloudRecords.decisionZone)
        #expect(Set(record.allKeys()) == ["choice", "devicePublicKey", "signature"])
        #expect(record["choice"] as? String == choice.rawValue)
        #expect(record["devicePublicKey"] as? Data == decision.devicePublicKey)
        #expect(record["signature"] as? Data == decision.signature)
        #expect(ApprovalCloudRecords.decision(from: record, for: fixture.request) == decision)
    }

    @Test("The iPhone subscription sends a visible mutable alert with Approve and Deny category")
    func visibleSubscription() async throws {
        let database = InMemoryApprovalCloudDatabase()
        let subscription = ApprovalCloudRecords.requestSubscription()
        try await database.save(subscription)
        let saved = try #require(database.subscriptions[subscription.subscriptionID] as? CKQuerySubscription)
        #expect(saved.zoneID == ApprovalCloudRecords.requestZone)
        #expect(saved.recordType == "ApprovalRequest")
        #expect(saved.querySubscriptionOptions == .firesOnRecordCreation)
        let notification = try #require(saved.notificationInfo)
        #expect(notification.title == "Login approval")
        #expect(notification.alertBody == "An agent is asking for a login. Open to review.")
        #expect(notification.category == "AGENT_KEYRING_APPROVAL")
        #expect(notification.shouldSendMutableContent)
        #expect(!notification.shouldSendContentAvailable)
        #expect(notification.desiredKeys == ["agentDisplayLabel", "expiresAt", "notificationCategory"])
        #expect(ApprovalCloudRecords.approveActionIdentifier == "APPROVE")
        #expect(ApprovalCloudRecords.denyActionIdentifier == "DENY")
    }

    @Test("Polling waits two seconds between fetches and a push only wakes a fetch")
    func cadenceAndWakeup() async throws {
        let fixture = try CloudApprovalFixture()
        var answers: [ApprovalDecision] = []
        let stream = fixture.channel.publish(fixture.request)
        let consumer = Task { for try await answer in stream { answers.append(answer) } }
        try await cloudEventually { fixture.clock.sleepDurations.count == 1 }
        #expect(fixture.clock.sleepDurations == [.seconds(2)])
        #expect(fixture.database.fetchedRecordIDs.isEmpty)
        fixture.clock.advance(seconds: 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.database.fetchedRecordIDs.isEmpty)
        fixture.clock.advance(seconds: 1)
        try await cloudEventually { fixture.clock.sleepDurations.count == 2 }
        #expect(fixture.database.fetchedRecordIDs == [ApprovalCloudRecords.decisionID(fixture.request.id)])
        fixture.channel.wakeUp(requestID: UUID())
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.database.fetchedRecordIDs.count == 1)
        fixture.channel.wakeUp(requestID: fixture.request.id)
        try await cloudEventually { fixture.clock.sleepDurations.count == 3 }
        #expect(fixture.database.fetchedRecordIDs.count == 2)
        #expect(answers.isEmpty)
        let answer = try fixture.decision(.approve)
        try await fixture.database.save(ApprovalCloudRecords.decision(answer))
        fixture.clock.advance(seconds: 2)
        try await cloudEventually { answers == [answer] && fixture.clock.sleepDurations.count == 4 }
        #expect(fixture.clock.sleepDurations.allSatisfy { $0 == .seconds(2) })
        fixture.channel.cancel(requestID: fixture.request.id)
        await fixture.channel.waitForCleanup(requestID: fixture.request.id)
        try await consumer.value
        fixture.expectCleanup()
    }

    @Test("Routing waits for cleanup on every outcome", arguments: ["approve", "deny", "block", "mac-approve", "mac-deny", "expired", "cancelled"])
    func cleanup(outcome: String) async throws {
        let macOutcome = outcome.hasPrefix("mac-")
        let fixture = try CloudApprovalFixture(locked: !macOutcome)
        let task = fixture.start()
        if macOutcome {
            try await cloudEventually { fixture.mac.requests.count == 1 && fixture.clock.hasRoutingTickSleep }
            fixture.clock.advance(seconds: 120)
        }
        try await cloudEventually { fixture.database.records[ApprovalCloudRecords.requestID(fixture.request.id)] != nil && fixture.clock.hasTwoSecondSleep }
        if outcome == "expired" {
            try await fixture.database.save(ApprovalCloudRecords.decision(try fixture.decision(.approve)))
            fixture.clock.advance(seconds: 600)
            await #expect(throws: CredentialReleaseAuthorizationError.expired) { try await task.value }
        } else if outcome == "cancelled" {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else if macOutcome {
            // A concurrent decision is removed even when the Mac finishes first.
            try await fixture.database.save(ApprovalCloudRecords.decision(try fixture.decision(.approve)))
            fixture.mac.complete(error: outcome == "mac-deny" ? .denied : nil)
            if outcome == "mac-deny" { await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await task.value } }
            else { try await task.value }
        } else {
            let choice: ApprovalChoice = outcome == "approve" ? .approve : outcome == "deny" ? .deny : .blockThisLogin
            try await fixture.database.save(ApprovalCloudRecords.decision(try fixture.decision(choice)))
            fixture.clock.advance(seconds: 2)
            if choice == .approve { try await task.value }
            else { await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await task.value } }
            #expect(fixture.blocked == (choice == .blockThisLogin))
        }
        fixture.expectCleanup()
        #expect(fixture.clock.sleepersAreEmpty)
    }

    @Test("Cancellation during publication deletes the record after its in-flight save completes")
    func cancellationDuringSave() async throws {
        let fixture = try CloudApprovalFixture()
        var saveContinuation: CheckedContinuation<Void, Never>?
        fixture.database.beforeSave = { _ in
            await withCheckedContinuation { saveContinuation = $0 }
        }
        let task = fixture.start()
        try await cloudEventually { saveContinuation != nil }
        task.cancel()
        saveContinuation?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        fixture.expectCleanup()
    }

    @Test("Authentication and quota failures fall back to the Mac on publication or polling", arguments:
        [CKError.Code.notAuthenticated, .quotaExceeded],
        [(true, InMemoryApprovalCloudDatabase.Operation.saveRecord), (false, .saveRecord), (true, .fetchRecord), (false, .fetchRecord)])
    func fallback(code: CKError.Code, scenario: (Bool, InMemoryApprovalCloudDatabase.Operation)) async throws {
        let (locked, operation) = scenario
        let fixture = try CloudApprovalFixture(locked: locked)
        fixture.database.failures[operation] = [CKError(code)]
        let task = fixture.start()
        if !locked {
            try await cloudEventually { fixture.mac.requests.count == 1 && fixture.clock.hasRoutingTickSleep }
            fixture.clock.advance(seconds: 120)
        }
        if operation == .fetchRecord {
            try await cloudEventually { fixture.clock.hasTwoSecondSleep }
            fixture.clock.advance(seconds: 2)
        }
        try await cloudEventually { fixture.progress.last?.iPhoneFailure != nil }
        #expect(fixture.progress.last?.iPhoneFailure == IPhoneApprovalFailure(cloudError: CKError(code)))
        #expect(fixture.progress.last?.phoneScheduledAt == nil)
        fixture.expectCleanup()
        if locked {
            #expect(fixture.mac.requests.isEmpty)
            #expect(fixture.progress.last?.phase == .waitingForUnlock)
            fixture.lock.isLocked = false
            fixture.clock.advance(seconds: 0.25)
        }
        try await cloudEventually { fixture.mac.requests.count == 1 }
        fixture.clock.advance(seconds: 120)
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.database.fetchedRecordIDs.count <= 1)
        #expect(fixture.database.records.isEmpty)
        fixture.mac.complete()
        try await task.value
        #expect(fixture.progress.last?.approvedOn == .mac)
        #expect(fixture.progress.last?.iPhoneFailure != nil)
    }

    @Test("Temporary polling failures keep the phone route alive until it answers or expires", arguments:
        [CKError.Code.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy], [true, false])
    func transientPollingFailure(code: CKError.Code, answers: Bool) async throws {
        let fixture = try CloudApprovalFixture()
        fixture.database.failures[.fetchRecord] = Array(repeating: CKError(code), count: answers ? 1 : 2)
        let task = fixture.start()
        try await cloudEventually { fixture.clock.hasTwoSecondSleep }
        fixture.clock.advance(seconds: 2)
        try await cloudEventually { fixture.database.fetchedRecordIDs.count == 1 && fixture.clock.hasTwoSecondSleep }
        #expect(fixture.progress.last?.iPhoneFailure == nil)
        #expect(fixture.database.records[ApprovalCloudRecords.requestID(fixture.request.id)] != nil)
        if answers {
            try await fixture.database.save(ApprovalCloudRecords.decision(try fixture.decision(.approve)))
            fixture.clock.advance(seconds: 2)
            try await task.value
            #expect(fixture.progress.last?.approvedOn == .iPhone)
        } else {
            fixture.clock.advance(seconds: 2)
            try await cloudEventually { fixture.database.fetchedRecordIDs.count == 2 && fixture.clock.hasTwoSecondSleep }
            #expect(fixture.progress.last?.iPhoneFailure == nil)
            fixture.clock.advance(seconds: 596)
            await #expect(throws: CredentialReleaseAuthorizationError.expired) { try await task.value }
        }
        fixture.expectCleanup()
    }

    @Test("CloudKit transport errors become fixed plain results", arguments:
        [CKError.Code.notAuthenticated, .networkUnavailable, .networkFailure, .quotaExceeded,
         .requestRateLimited, .serviceUnavailable, .zoneBusy, .permissionFailure, .badContainer])
    func errorMapping(code: CKError.Code) {
        let expected: [CKError.Code: IPhoneApprovalFailure] = [
            .notAuthenticated: .notSignedInToICloud, .networkUnavailable: .networkUnavailable,
            .networkFailure: .networkUnavailable, .quotaExceeded: .quotaExceeded,
            .requestRateLimited: .rateLimited, .serviceUnavailable: .rateLimited, .zoneBusy: .rateLimited,
            .permissionFailure: .unavailable, .badContainer: .unavailable]
        #expect(IPhoneApprovalFailure(cloudError: CKError(code)) == expected[code])
        #expect(IPhoneApprovalFailure(cloudError: CocoaError(.fileReadUnknown)) == .unavailable)
    }

    @Test("Unknown, malformed and forged decisions cannot approve; a valid decision still can")
    func ignoredDecisions() async throws {
        let fixture = try CloudApprovalFixture()
        let unknown = ApprovalDecision(requestID: UUID(), choice: .approve, devicePublicKey: Data(), signature: Data())
        let unknownRecord = ApprovalCloudRecords.decision(unknown)
        try await fixture.database.save(unknownRecord)
        let task = fixture.start()
        try await cloudEventually { fixture.clock.hasTwoSecondSleep }
        fixture.clock.advance(seconds: 2)
        try await cloudEventually { fixture.database.fetchedRecordIDs.count == 1 && fixture.clock.hasTwoSecondSleep }
        #expect(fixture.progress.last?.approvedAt == nil)
        #expect(!fixture.database.fetchedRecordIDs.contains(unknownRecord.recordID))
        #expect(ApprovalCloudRecords.decision(from: unknownRecord, for: fixture.request) == nil)
        let malformed = CKRecord(recordType: "ApprovalDecision", recordID: ApprovalCloudRecords.decisionID(fixture.request.id))
        malformed["choice"] = "approve" as CKRecordValue
        try await fixture.database.save(malformed)
        fixture.clock.advance(seconds: 2)
        try await cloudEventually { fixture.database.fetchedRecordIDs.count == 2 && fixture.clock.hasTwoSecondSleep }
        #expect(fixture.progress.last?.approvedAt == nil)
        let forged = ApprovalDecision(requestID: fixture.request.id, choice: .approve,
            devicePublicKey: fixture.key.publicKey.x963Representation, signature: Data("forged".utf8))
        try await fixture.database.save(ApprovalCloudRecords.decision(forged))
        fixture.clock.advance(seconds: 2)
        try await cloudEventually { fixture.database.fetchedRecordIDs.count == 3 && fixture.clock.hasTwoSecondSleep }
        #expect(fixture.progress.last?.approvedAt == nil)
        try await fixture.database.save(ApprovalCloudRecords.decision(try fixture.decision(.approve)))
        fixture.clock.advance(seconds: 2)
        try await task.value
        #expect(fixture.progress.last?.approvedOn == .iPhone)
        #expect(fixture.database.records.keys.contains(unknownRecord.recordID))
        fixture.expectCleanup(allowUnknownRecord: true)
    }

    @Test("An expired request never publishes or yields its preexisting decision")
    func expiredRequest() async throws {
        let fixture = try CloudApprovalFixture()
        try await fixture.database.save(ApprovalCloudRecords.decision(try fixture.decision(.approve)))
        fixture.clock.advance(seconds: 600)
        var answers: [ApprovalDecision] = []
        for try await answer in fixture.channel.publish(fixture.request) { answers.append(answer) }
        await fixture.channel.waitForCleanup(requestID: fixture.request.id)
        #expect(answers.isEmpty)
        #expect(fixture.database.fetchedRecordIDs.isEmpty)
        #expect(fixture.clock.sleepDurations.isEmpty)
        fixture.expectCleanup()
    }

    @Test("Cleanup still attempts the second record if deleting the first fails")
    func cleanupFailure() async throws {
        let fixture = try CloudApprovalFixture()
        fixture.database.failures[.deleteRecord] = [CKError(.networkUnavailable)]
        let stream = fixture.channel.publish(fixture.request)
        let consumer = Task { for try await _ in stream {} }
        try await cloudEventually { fixture.clock.hasTwoSecondSleep }
        fixture.channel.cancel(requestID: fixture.request.id)
        await fixture.channel.waitForCleanup(requestID: fixture.request.id)
        try await consumer.value
        #expect(fixture.database.deletedRecordIDs == [ApprovalCloudRecords.requestID(fixture.request.id), ApprovalCloudRecords.decisionID(fixture.request.id)])
        #expect(fixture.database.records.count == 1)
    }
}

private struct CloudPairedKeys: PairedDevicePublicKeyProviding {
    let keys: [Data]
    func pairedDevicePublicKeys() async throws -> [Data] { keys }
}

@MainActor
private final class CloudApprovalClock {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    var sleepDurations: [Duration] = []
    private var sleepers: [UUID: (Date, Duration, CheckedContinuation<Void, Error>)] = [:]
    var hasTwoSecondSleep: Bool { sleepers.values.contains { $0.1 == .seconds(2) } }
    var hasRoutingTickSleep: Bool { sleepers.values.contains { $0.1 == .milliseconds(250) } }
    var sleepersAreEmpty: Bool { sleepers.isEmpty }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (now.addingTimeInterval(seconds), duration, continuation)
                sleepDurations.append(duration)
            }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.2.resume(throwing: CancellationError()) }
        }
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for (id, sleeper) in sleepers.filter({ $0.value.0 <= now }) {
            sleepers.removeValue(forKey: id)
            sleeper.2.resume()
        }
    }
}

@MainActor
private final class CloudApprovalFixture {
    let database = InMemoryApprovalCloudDatabase()
    let clock = CloudApprovalClock()
    let key = P256.Signing.PrivateKey()
    let lock: FakeCredentialSessionLockState
    let mac = FakeCredentialAuthorizer()
    let request: ApprovalRequest
    let channel: CloudKitIPhoneApprovalChannel
    let coordinator: CredentialApprovalCoordinator
    var progress: [AgentApprovalProgress] = []
    var blocked = false

    init(locked: Bool = true) throws {
        lock = FakeCredentialSessionLockState(isLocked: locked)
        request = try ApprovalRequest(agentDisplayLabel: "Test agent", site: "example.com", account: "synthetic",
            field: .password, action: .acquire, createdAt: clock.now)
        let start = clock.now
        let devices = CloudPairedKeys(keys: [key.publicKey.x963Representation])
        channel = CloudKitIPhoneApprovalChannel(database: database, now: { [clock] in clock.now },
            sleep: { [clock] in try await clock.sleep($0) })
        coordinator = CredentialApprovalCoordinator(lockState: lock, phoneChannel: channel, pairedDevices: devices,
            verifier: ApprovalDecisionVerifier(pairedDevices: devices, now: { start }),
            now: { [clock] in clock.now }, sleep: { [clock] in try await clock.sleep($0) })
    }

    func start() -> Task<Void, Error> {
        Task { @MainActor in
            try await coordinator.authorize(credentialID: UUID(), authorizationDeadline: Date(timeIntervalSince1970: Double(request.expiresAt)),
                approvalRequest: request, cancelPrompt: { self.mac.cancelCurrentAuthorization() },
                onBlockLogin: { self.blocked = true }, onProgress: { self.progress.append($0) }) {
                    try await self.mac.authorize(CredentialReleaseAuthorizationRequest(destination: "example.com", account: "synthetic", field: .password),
                        onPromptStarted: $0)
                }
        }
    }

    func decision(_ choice: ApprovalChoice) throws -> ApprovalDecision {
        ApprovalDecision(requestID: request.id, choice: choice, devicePublicKey: key.publicKey.x963Representation,
            signature: try key.signature(for: request.signedFields.canonicalBytes(for: choice)).derRepresentation)
    }

    func expectCleanup(allowUnknownRecord: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(database.records[ApprovalCloudRecords.requestID(request.id)] == nil, sourceLocation: sourceLocation)
        #expect(database.records[ApprovalCloudRecords.decisionID(request.id)] == nil, sourceLocation: sourceLocation)
        #expect(database.deletedRecordIDs == [ApprovalCloudRecords.requestID(request.id), ApprovalCloudRecords.decisionID(request.id)], sourceLocation: sourceLocation)
        if !allowUnknownRecord { #expect(database.records.isEmpty, sourceLocation: sourceLocation) }
    }
}

@MainActor
private func cloudEventually(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw CloudApprovalTestError.expectedEventDidNotArrive
}

private enum CloudApprovalTestError: Error { case expectedEventDidNotArrive }
