// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// One world both the Mac's screens and the iPhone's run on, with no iCloud,
// relay, Keychain, Face ID or Touch ID behind them. An action first runs as
// SandboxEffectRunner says (at once, after a wait, failed or cancelled), then
// changes the world through the same rules the real devices follow: rule
// changes through RuleChangePlan, the device list through DevicesSnapshot,
// first run through PhoneFirstRun and adding Apple Watch through
// PhoneAddWatch. Answers to a request set its state as the Mac commits them;
// that step has no shared reducer to call, since the real one works on
// sealed protobuf work items (CredentialRequestLifecycle).

import Foundation

@MainActor
public final class SandboxWorld {
    public private(set) var state: SandboxState {
        didSet { revision &+= 1; publish() }
    }
    public let effects: SandboxEffectRunner
    /// Goes up with every change, so a screen never takes an older snapshot for a newer one.
    public private(set) var revision: UInt64 = 1
    private var observers: [UUID: AsyncStream<SandboxState>.Continuation] = [:]

    public init(_ state: SandboxState = .builtIn(), effects: SandboxEffectRunner = SandboxEffectRunner()) {
        self.state = state
        self.effects = effects
    }

    /// The world now, then each time it changes.
    public func changes() -> AsyncStream<SandboxState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers.removeValue(forKey: id) } }
        }
    }

    private func publish() {
        for observer in observers.values { observer.yield(state) }
    }

    /// Changes the world directly, for a gallery or a test that starts somewhere particular.
    public func set(_ change: (inout SandboxState) -> Void) { change(&state) }

    // MARK: Rules

    /// What changing these logins to `rule` would do.
    public func plan(_ rule: LoginRule, for loginIDs: [String]) -> RuleChangePlan<String> {
        let picked = Set(loginIDs)
        return RuleChangePlan(target: rule, selected: state.logins.filter { picked.contains($0.id) }.map(planned))
    }

    func planned(_ login: SandboxLogin) -> RuleChangePlanLogin<String> {
        let live = state.requests.filter { $0.loginID == login.id && $0.request.state.isInUse }
        return .init(id: login.id, rule: login.rule, holdsSecret: login.holdsSecret, activeLeases: live.count,
                     automaticLeases: live.filter(\.request.byAutomaticRule).count)
    }

    /// After the approval: the plan's logins take the rule, Blocked deletes their passwords, and the grants it ends
    /// end. As on the Mac (CredentialLeaseStore), Blocked ends every request still open for the login, waiting
    /// or in use, so none can be approved after it; leaving Automatic ends the grants that rule gave.
    public func setLoginRule(_ rule: LoginRule, for loginIDs: [String]) async throws {
        let plan = plan(rule, for: loginIDs)
        guard !plan.isNoOp else { return }
        try await effects.runEffect(.setRule)
        let affected = Set(plan.affectedLoginIDs)
        var next = state
        for index in next.logins.indices where affected.contains(next.logins[index].id) {
            let previous = next.logins[index].rule
            next.logins[index].rule = rule
            if rule == .blocked { next.logins[index].secretDeleted = true }
            for request in next.requests.indices where next.requests[request].loginID == next.logins[index].id {
                let open = next.requests[request].request.state
                let ends = rule == .blocked ? Self.isOpen(open)
                    : previous == .automatic && open.isInUse && next.requests[request].request.byAutomaticRule
                if ends { next.requests[request].request.state = .ended(at: .now) }
            }
        }
        state = next
    }

    /// Waiting for an answer, answered and not yet committed, or in use: a lease the Mac still holds open.
    private static func isOpen(_ state: AccessRequestState) -> Bool {
        switch state {
        case .waitingForYou, .sendingAnswer, .waitingForMac, .approved: true
        case .denied, .unanswered, .cancelled, .expired, .released, .ended, .blockedByRule: false
        }
    }

    // MARK: Requests

    public func accessRequest(_ id: String) -> AccessRequest? {
        state.requests.first { $0.id == id }?.request ?? (state.phone.practiceRequest?.id == id ? state.phone.practiceRequest : nil)
    }

    @discardableResult
    public func approveAccessRequest(_ id: String, on surface: ApprovalSurface) async throws -> AccessRequestState {
        try await effects.runEffect(.approve)
        return answer(id, .approved(by: surface, until: .now.addingTimeInterval(RequestedAccess.longestLease)))
    }

    @discardableResult
    public func denyAccessRequest(_ id: String, reply: String?, on surface: ApprovalSurface) async throws -> AccessRequestState {
        try await effects.runEffect(.deny)
        let reply = reply.flatMap { $0.isEmpty ? nil : $0 }
        return answer(id, .denied(by: surface, reply: reply, askAgainAfter: .now.addingTimeInterval(RequestedAccess.longestLease)))
    }

    /// Ends a grant early.
    @discardableResult
    public func stopRequest(_ id: String) async throws -> AccessRequestState {
        try await effects.runEffect(.stop)
        return answer(id, .ended(at: .now), onlyIf: \.isInUse)
    }

    /// Lifts a denial's hold-off, so the agent may ask again.
    @discardableResult
    public func allowAskingAgain(_ id: String) async throws -> AccessRequestState {
        try await effects.runEffect(.allowAskingAgain)
        guard let index = state.requests.firstIndex(where: { $0.id == id }),
              case let .denied(by, reply, _) = state.requests[index].request.state else { return accessRequest(id)?.state ?? .unanswered }
        state.requests[index].request.state = .denied(by: by, reply: reply, askAgainAfter: nil)
        return state.requests[index].request.state
    }

    /// An answer lands only on a request still waiting (or, for Stop, still in use): a late one changes nothing.
    private func answer(_ id: String, _ next: AccessRequestState, onlyIf open: (AccessRequestState) -> Bool = \.isWaitingForYou) -> AccessRequestState {
        guard let index = state.requests.firstIndex(where: { $0.id == id }) else { return accessRequest(id)?.state ?? next }
        guard open(state.requests[index].request.state) else { return state.requests[index].request.state }
        state.requests[index].request.state = next
        return next
    }

    // MARK: Devices

    /// Removes a device, and the computer that is its other half; or a computer alone.
    public func removeDevice(_ id: String) async throws {
        try await effects.runEffect(.removeDevice)
        var next = state
        next.devices.removeAll { $0.id == id }
        next.computers.removeAll { $0.id == id || $0.pairedDeviceID == id }
        state = next
    }

    /// Renames the one entry, as the Mac does (MacSyncCoordinator.renameConfirmed): a Mac's computer half keeps its name.
    public func renameDevice(_ id: String, to name: String) async throws {
        try await effects.runEffect(.renameDevice)
        var next = state
        if let index = next.devices.firstIndex(where: { $0.id == id }) {
            next.devices[index].name = name
        } else if let index = next.computers.firstIndex(where: { $0.id == id }) {
            next.computers[index].name = name
        }
        state = next
    }

    /// A practice request to a device he answers on, from its row.
    public func sendPracticeRequest(toDevice deviceID: String) async throws {
        state.practice[deviceID] = .sending
        do {
            try await effects.runEffect(.sendPractice)
            state.practice[deviceID] = .withApple
        } catch {
            state.practice[deviceID] = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            throw error
        }
    }

    public func addPassword(site: String, account: String, rule: LoginRule, totpSeed: String?) async throws {
        try await effects.runEffect(.addPassword)
        state.logins.append(SandboxLogin(id: UUID().uuidString, site: site, account: account, rule: rule,
                                         totpSeed: totpSeed.map { _ in SandboxSecrets.totpSeed }))
    }

    /// Back to first run, with nothing on this device.
    public func resetSandboxWorld() async throws {
        try await effects.runEffect(.reset)
        state = SandboxState(logins: [], devices: [], computers: [], thisDeviceID: state.thisDeviceID, phone: PhoneSnapshot(firstRun: .start))
    }

    /// Changes nothing in a world with no iCloud, but still runs, so a test can make it wait or fail.
    public func sync() async throws {
        try await effects.runEffect(.sync)
    }
}
