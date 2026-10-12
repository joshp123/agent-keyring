import AgentKeyringTestSupport
import CryptoKit
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Mac and iPhone approval routing")
struct PhoneApprovalRoutingTests {
    @Test("A locked or sleeping Mac asks the paired phone without starting a Mac prompt", arguments: [true, false])
    func unavailableMac(screenLocked: Bool) async throws {
        let fixture = try PhoneRoutingFixture(screenLocked: screenLocked, displayAsleep: !screenLocked)
        let task = fixture.start()
        try await routingEventually { fixture.phone.requests.count == 1 }
        #expect(fixture.mac.requests.isEmpty)
        #expect(fixture.progress.last?.macWasLocked == true)
        #expect(fixture.progress.last?.macWasAsleep == !screenLocked)
        fixture.phone.answer(try fixture.decision(.approve))
        try await task.value
        #expect(fixture.progress.last?.approvedOn == .iPhone)
        #expect(fixture.phone.cancelledRequestIDs == [fixture.request.id])
    }

    @Test("Unavailable Mac authentication asks a paired phone immediately", arguments: [true, false])
    func noMacAuthentication(paired: Bool) async throws {
        let fixture = try PhoneRoutingFixture(paired: paired)
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 }
        fixture.mac.complete(error: .unavailable)
        if paired {
            try await routingEventually { fixture.phone.requests.count == 1 }
            #expect(fixture.clock.now == fixture.request.createdAt)
            #expect(fixture.progress.last?.provider == .iPhone)
            fixture.phone.answer(try fixture.decision(.approve))
            try await task.value
            #expect(fixture.progress.last?.approvedOn == .iPhone)
            #expect(fixture.mac.requests.count == 1)
        } else {
            await #expect(throws: CredentialReleaseAuthorizationError.unavailable) { try await task.value }
            #expect(fixture.phone.requests.isEmpty)
        }
    }

    @Test("An unlocked Mac escalates at the configured delay", arguments: [120, 75, 180])
    func escalation(delay: Int) async throws {
        let fixture = try PhoneRoutingFixture(delay: delay)
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 && fixture.clock.tickSleepCount > 0 }
        #expect(fixture.phone.requests.isEmpty)
        #expect(fixture.progress.last?.phoneScheduledAt == fixture.clock.now.addingTimeInterval(Double(delay)))
        let sleeps = fixture.clock.sleepCount
        fixture.clock.advance(seconds: Double(delay - 1))
        try await routingEventually { fixture.clock.sleepCount > sleeps }
        #expect(fixture.phone.requests.isEmpty)
        fixture.clock.advance(seconds: 1)
        try await routingEventually { fixture.phone.requests.count == 1 }
        fixture.phone.answer(try fixture.decision(.approve))
        try await task.value
        #expect(fixture.mac.cancellations == 1)
        #expect(fixture.progress.last?.approvedOn == .iPhone)
    }

    @Test("The first answer cancels the other prompt, including a decline", arguments: ["mac", "phone", "phone-deny"])
    func firstAnswer(winner: String) async throws {
        let fixture = try PhoneRoutingFixture()
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 && fixture.clock.tickSleepCount > 0 }
        fixture.clock.advance(seconds: 120)
        try await routingEventually { fixture.phone.requests.count == 1 }
        if winner == "mac" {
            fixture.mac.complete()
            try await task.value
            #expect(fixture.progress.last?.approvedOn == .mac)
            fixture.phone.answer(try fixture.decision(.deny))
        } else {
            fixture.phone.answer(try fixture.decision(winner == "phone" ? .approve : .deny))
            if winner == "phone" { try await task.value }
            else { await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await task.value } }
            #expect(fixture.mac.cancellations == 1)
            fixture.mac.complete()
        }
        #expect(fixture.phone.cancelledRequestIDs == [fixture.request.id])
    }

    @Test("A signed decision for B on A's stream neither approves A nor consumes B's receipt")
    func crossRequestDecision() async throws {
        let fixture = try PhoneRoutingFixture(screenLocked: true)
        let task = fixture.start()
        try await routingEventually { fixture.phone.requests.count == 1 }
        let requestB = try ApprovalRequest(agentDisplayLabel: "Second agent", site: "second.example.com",
            account: "synthetic", field: .password, action: .acquire, createdAt: fixture.clock.now)
        try await fixture.verifier.register(requestB)
        let decisionB = ApprovalDecision(requestID: requestB.id, choice: .approve,
            devicePublicKey: fixture.key.publicKey.x963Representation,
            signature: try fixture.key.signature(for: requestB.signedFields.canonicalBytes(for: .approve)).derRepresentation)
        fixture.phone.answer(decisionB, on: fixture.request.id)
        fixture.phone.answer(try fixture.decision(.deny))
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await task.value }
        #expect(fixture.progress.last?.approvedAt == nil)
        #expect(try await fixture.verifier.verify(decisionB) == .approve)
    }

    @Test("A forged decision leaves both prompts waiting and a later valid answer succeeds")
    func forgedDecision() async throws {
        let fixture = try PhoneRoutingFixture()
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 && fixture.clock.tickSleepCount > 0 }
        fixture.clock.advance(seconds: 120)
        try await routingEventually { fixture.phone.requests.count == 1 }
        fixture.phone.answer(ApprovalDecision(requestID: fixture.request.id, choice: .approve,
            devicePublicKey: fixture.key.publicKey.x963Representation, signature: Data("forged".utf8)))
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.progress.last?.approvedAt == nil)
        #expect(fixture.phone.cancelledRequestIDs.isEmpty)
        #expect(fixture.mac.cancellations == 0)
        fixture.phone.answer(try fixture.decision(.approve))
        try await task.value
    }

    @Test("A lock during the Mac prompt keeps the same request and asks the phone immediately")
    func lockDuringPrompt() async throws {
        let fixture = try PhoneRoutingFixture()
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 && fixture.clock.tickSleepCount > 0 }
        fixture.lock.screenLocked = true
        fixture.clock.advance(seconds: 0.25)
        try await routingEventually { fixture.phone.requests.count == 1 }
        #expect(fixture.mac.cancellations == 1)
        #expect(fixture.phone.requests.first?.id == fixture.request.id)
        #expect(fixture.clock.now < fixture.request.createdAt.addingTimeInterval(120))
        fixture.phone.answer(try fixture.decision(.approve))
        try await task.value
    }

    @Test("Without a paired phone a lock returns to waiting, then asks the Mac again on unlock")
    func lockWithoutPhone() async throws {
        let fixture = try PhoneRoutingFixture(paired: false)
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 }
        fixture.lock.screenLocked = true
        fixture.clock.advance(seconds: 0.25)
        try await routingEventually { fixture.progress.last?.phase == .waitingForUnlock && fixture.clock.activeTickSleepCount > 0 }
        #expect(fixture.mac.cancellations == 1)
        #expect(fixture.phone.requests.isEmpty)
        #expect(fixture.progress.last?.askedAt == nil)
        fixture.lock.screenLocked = false
        fixture.clock.advance(seconds: 1)
        try await routingEventually { fixture.mac.requests.count == 2 }
        fixture.mac.complete()
        try await task.value
    }

    @Test("A Mac approval returned while locked does not approve the request")
    func macApprovalWhileLocked() async throws {
        let fixture = try PhoneRoutingFixture()
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 && fixture.clock.tickSleepCount > 0 }
        fixture.lock.screenLocked = true
        fixture.mac.complete()
        try await routingEventually { fixture.phone.requests.count == 1 }
        #expect(fixture.progress.last?.approvedOn == nil)
        #expect(fixture.phone.cancelledRequestIDs.isEmpty)
        fixture.phone.answer(try fixture.decision(.approve))
        try await task.value
        #expect(fixture.progress.last?.approvedOn == .iPhone)
    }

    @Test("Unlock after asking the phone also asks on the Mac, and the first answer wins", arguments: [true, false])
    func unlockAfterPhone(macWins: Bool) async throws {
        let fixture = try PhoneRoutingFixture(screenLocked: true)
        let task = fixture.start()
        try await routingEventually { fixture.phone.requests.count == 1 && fixture.clock.activeTickSleepCount > 0 }
        fixture.lock.screenLocked = false
        fixture.clock.advance(seconds: 0.25)
        try await routingEventually { fixture.mac.requests.count == 1 && fixture.clock.activeTickSleepCount == 0 }
        #expect(fixture.progress.last?.provider == .mac)
        #expect(fixture.progress.last?.phoneScheduledAt == nil)
        #expect(fixture.phone.requests.count == 1)
        if macWins { fixture.mac.complete() }
        else { fixture.phone.answer(try fixture.decision(.approve)) }
        try await task.value
        #expect(fixture.progress.last?.approvedOn == (macWins ? .mac : .iPhone))
        #expect(fixture.phone.cancelledRequestIDs == [fixture.request.id])
    }

    @Test("The quarter-second tick stops after escalation while both prompts wait")
    func tickStopsAfterEscalation() async throws {
        let fixture = try PhoneRoutingFixture()
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 && fixture.clock.activeTickSleepCount > 0 }
        fixture.clock.advance(seconds: 120)
        try await routingEventually { fixture.phone.requests.count == 1 && fixture.clock.activeTickSleepCount == 0 }
        let tickCount = fixture.clock.tickSleepCount
        fixture.clock.advance(seconds: 30)
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.clock.tickSleepCount == tickCount)
        fixture.phone.answer(try fixture.decision(.approve))
        try await task.value
    }

    @Test("No paired device means no phone publication or escalation time")
    func noPairedDevice() async throws {
        let fixture = try PhoneRoutingFixture(paired: false)
        let task = fixture.start()
        try await routingEventually { fixture.mac.requests.count == 1 }
        fixture.clock.advance(seconds: 180)
        for _ in 0..<100 { await Task.yield() }
        #expect(fixture.clock.tickSleepCount == 0)
        #expect(fixture.phone.requests.isEmpty)
        #expect(fixture.progress.last?.phoneScheduledAt == nil)
        fixture.mac.complete()
        try await task.value
    }

    @Test("A locked Mac publishes different login requests to the phone without serializing their answers")
    func independentPhoneRequests() async throws {
        let fixture = try PhoneRoutingFixture(screenLocked: true)
        let secondRequest = try ApprovalRequest(agentDisplayLabel: "Second agent", site: "second.example.com",
            account: "synthetic", field: .password, action: .acquire, createdAt: fixture.clock.now)
        let first = fixture.start()
        try await routingEventually { fixture.phone.requests.count == 1 }
        let second = Task { @MainActor in
            try await fixture.approvals.authorize(credentialID: UUID(), requesterIdentity: syntheticVerifiedRequester.verifiedIdentity,
                authorizationDeadline: secondRequest.createdAt.addingTimeInterval(600),
                approvalRequest: secondRequest) { _ in Issue.record("Locked request started a Mac prompt") }
        }
        try await routingEventually { fixture.phone.requests.count == 2 }
        let secondDecision = ApprovalDecision(requestID: secondRequest.id, choice: .approve,
            devicePublicKey: fixture.key.publicKey.x963Representation,
            signature: try fixture.key.signature(for: secondRequest.signedFields.canonicalBytes(for: .approve)).derRepresentation)
        fixture.phone.answer(secondDecision)
        try await second.value
        #expect(fixture.phone.cancelledRequestIDs == [secondRequest.id])
        fixture.phone.answer(try fixture.decision(.approve))
        try await first.value
    }

    @Test("An unanswered phone request expires and its publication is cancelled")
    func phoneExpiry() async throws {
        let fixture = try PhoneRoutingFixture(screenLocked: true)
        let task = fixture.start()
        try await routingEventually { fixture.phone.requests.count == 1 && fixture.clock.tickSleepCount > 0 }
        fixture.clock.advance(seconds: 600)
        await #expect(throws: CredentialReleaseAuthorizationError.expired) { try await task.value }
        #expect(fixture.phone.cancelledRequestIDs == [fixture.request.id])
    }

    @Test("A signed phone block declines now and is staged for the next authenticated rules save")
    func blockLogin() async throws {
        let fixture = try PhoneRoutingFixture(screenLocked: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let signer = FakeAccessRulesSigner()
        let store = CredentialAccessPolicyStore(fileURL: root.appendingPathComponent("rules.json"), signer: signer)
        try await confirmInitialAccessRules(in: store)
        let control = CredentialAccessController(store: store)
        let loginID = UUID()
        let generation = MirrorGeneration(id: UUID(), previousGenerationID: nil, createdAt: Date(),
            sourceExportedAt: Date(), scope: .full, exporterIdentifier: "fixture", exporterDisplayName: "Fixture",
            items: [MirrorItem(id: loginID,
                sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
                title: "example.com", origins: ["https://example.com"],
                credentials: [.password(userName: "synthetic", password: "test-password")])], skippedCredentialCount: 0)
        await control.refresh(from: generation)
        let task = fixture.start(onBlock: { control.stagePhoneBlock(for: loginID) })
        try await routingEventually { fixture.phone.requests.count == 1 }
        fixture.phone.answer(try fixture.decision(.blockThisLogin))
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await task.value }
        #expect(control.hasPendingPhoneBlock(for: loginID))
        #expect(control.policy(for: loginID) == .block)
        #expect(try await store.load()[loginID] == nil)
        await control.refresh(from: generation)
        #expect(control.policy(for: loginID) == .block)
        #expect(control.rows.first?.policy == .block)
        let refusingStore = CredentialAccessPolicyStore(fileURL: root.appendingPathComponent("rules.json"),
            signer: FakeAccessRulesSigner(refusesSigning: true, signedBytes: try Data(contentsOf: root.appendingPathComponent("rules.json"))))
        let refusingControl = CredentialAccessController(store: refusingStore)
        await refusingControl.refresh(from: generation)
        refusingControl.stagePhoneBlock(for: loginID)
        await refusingControl.setPolicy(.ask, for: [loginID])
        #expect(refusingControl.hasPendingPhoneBlock(for: loginID))
        #expect(try await store.load()[loginID] == nil)
        await control.setPolicy(.ask, for: [loginID])
        #expect(!control.hasPendingPhoneBlock(for: loginID))
        #expect(try await store.load()[loginID] == nil)
        #expect(control.policy(for: loginID) == .ask)
        #expect(signer.signingReason == "confirm your Agent Keyring access rules")
        try FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }

    @Test("The one routing setting defaults to 120 seconds and persists a custom delay")
    func persistedDelay() throws {
        let suite = "PhoneRoutingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ApprovalRoutingSettings(defaults: defaults)
        #expect(settings.phoneDelaySeconds == 120)
        settings.phoneDelaySeconds = 90
        #expect(ApprovalRoutingSettings(defaults: defaults).phoneDelaySeconds == 90)
        settings.phoneDelaySeconds = 0
        #expect(settings.phoneDelaySeconds == 1)
        settings.phoneDelaySeconds = Int.max
        #expect(settings.phoneDelaySeconds == Int(ApprovalRequest.lifetimeSeconds))
        defaults.set(-1, forKey: "phoneApprovalDelaySeconds")
        #expect(ApprovalRoutingSettings(defaults: defaults).phoneDelaySeconds == 1)
        defaults.set(Int.max, forKey: "phoneApprovalDelaySeconds")
        #expect(ApprovalRoutingSettings(defaults: defaults).phoneDelaySeconds == Int(ApprovalRequest.lifetimeSeconds))
    }
}

private struct RoutingPairedKeys: PairedDevicePublicKeyProviding {
    let keys: [Data]
    func pairedDevicePublicKeys() async throws -> [Data] { keys }
}

@MainActor
private final class RoutingLockState: CredentialSessionLockState {
    private let stateChanges = AsyncStream<Void>.makeStream()
    var changes: AsyncStream<Void> { stateChanges.stream }
    var screenLocked: Bool { didSet { stateChanges.continuation.yield(()) } }
    var displayAsleep: Bool { didSet { stateChanges.continuation.yield(()) } }
    var isDisplayAsleep: Bool { displayAsleep }
    var isLocked: Bool { screenLocked || displayAsleep }
    init(screenLocked: Bool, displayAsleep: Bool) {
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
    }
}

@MainActor
private final class RoutingClock {
    var now: Date
    var sleepCount = 0
    var tickSleepCount = 0
    private var tickSleepIDs: Set<UUID> = []
    var activeTickSleepCount: Int { tickSleepIDs.count }
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, Error>)] = [:]
    init(now: Date) { self.now = now }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (now.addingTimeInterval(seconds), continuation)
                sleepCount += 1
                if duration == .milliseconds(250) {
                    tickSleepCount += 1
                    tickSleepIDs.insert(id)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.tickSleepIDs.remove(id)
                self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let ready = sleepers.filter { $0.value.0 <= now }
        for (id, sleeper) in ready {
            sleepers.removeValue(forKey: id)
            tickSleepIDs.remove(id)
            sleeper.1.resume()
        }
    }
}

@MainActor
private final class PhoneRoutingFixture {
    let key = P256.Signing.PrivateKey()
    let clock: RoutingClock
    let lock: RoutingLockState
    let phone = FakeIPhoneApprovalChannel()
    let mac = FakeCredentialAuthorizer()
    let request: ApprovalRequest
    let approvals: CredentialApprovalCoordinator
    let verifier: ApprovalDecisionVerifier
    var progress: [AgentApprovalProgress] = []

    init(screenLocked: Bool = false, displayAsleep: Bool = false, delay: Int = 120, paired: Bool = true) throws {
        let start = Date()
        clock = RoutingClock(now: start)
        lock = RoutingLockState(screenLocked: screenLocked, displayAsleep: displayAsleep)
        request = try ApprovalRequest(agentDisplayLabel: "Test agent", site: "example.com", account: "synthetic",
            field: .password, action: .acquire, createdAt: start)
        let devices = RoutingPairedKeys(keys: paired ? [key.publicKey.x963Representation] : [])
        verifier = ApprovalDecisionVerifier(pairedDevices: devices, now: { start })
        approvals = CredentialApprovalCoordinator(lockState: lock, phoneChannel: phone,
            pairedDevices: devices, verifier: verifier, phoneDelay: { Double(delay) },
            now: { [clock] in clock.now }, sleep: { [clock] in try await clock.sleep($0) })
    }

    func start(onBlock: @escaping () -> Void = {}) -> Task<Void, Error> {
        Task { @MainActor in
            try await approvals.authorize(credentialID: UUID(), requesterIdentity: syntheticVerifiedRequester.verifiedIdentity, authorizationDeadline: request.createdAt.addingTimeInterval(600),
                approvalRequest: request, cancelPrompt: { self.mac.cancelCurrentAuthorization() },
                onBlockLogin: onBlock, onProgress: { self.progress.append($0) }) {
                    try await self.mac.authorize(CredentialReleaseAuthorizationRequest(destination: "example.com",
                        account: "synthetic", field: .password), onPromptStarted: $0)
                }
        }
    }

    func decision(_ choice: ApprovalChoice) throws -> ApprovalDecision {
        ApprovalDecision(requestID: request.id, choice: choice, devicePublicKey: key.publicKey.x963Representation,
            signature: try key.signature(for: request.signedFields.canonicalBytes(for: choice)).derRepresentation)
    }
}

@MainActor
private func routingEventually(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw RoutingTestError.expectedEventDidNotArrive
}

private enum RoutingTestError: Error { case expectedEventDidNotArrive }
