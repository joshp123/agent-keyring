// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Mac screens' backends over the release 2 lease store (RFC 0007, U2 and
// U3). Plumbing only: approval, denial and revocation are the store's.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
extension MirrorAppModel {
    /// The screen value for one lease, with its requester and login.
    @MainActor
    public func accessRequest(for lease: Agentkeyring_V1_Lease) -> AccessRequest {
        LeaseScreenMapping.accessRequest(lease, requester: leaseStore.requester(for: lease.leaseID),
            login: leaseLogins.first { $0.id.uuidString == lease.loginID })
    }
}

/// U2: the approval panel answers through the store, with Touch ID evaluated
/// in the panel's own context so a touch alone approves.
@available(macOS 26.0, *)
@MainActor
public final class LeaseApprovalBackend: MacApprovalBackend {
    private let model: MirrorAppModel
    private var contexts: [String: LAContext] = [:]

    public init(model: MirrorAppModel) {
        self.model = model
    }

    public func updates(requestID: String) -> AsyncStream<AccessRequest> {
        let model = model
        return streamUntilFinal(Observations {
            model.leaseStore.leases.first { $0.leaseID == requestID }.map(model.accessRequest(for:))
        })
    }

    /// Nil when this Mac has no usable Touch ID sensor (a closed laptop, say):
    /// the panel then offers the Approve button and the system prompt, which
    /// can use an Apple Watch.
    public func embeddedTouchIDContext(requestID: String) -> LAContext? {
        if let context = contexts[requestID] { return context }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        context.touchIDAuthenticationAllowableReuseDuration = 0
        contexts[requestID] = context
        return context
    }

    public func approve(requestID: String) async throws -> AccessRequestState {
        defer { contexts[requestID] = nil }
        let lease = if let context = contexts[requestID] {
            try await model.approveLeaseWithTouchID(requestID, context: context)
        } else {
            try await model.approveLeaseWithTouchID(requestID)
        }
        return model.accessRequest(for: lease).state
    }

    public func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        contexts[requestID] = nil
        return model.accessRequest(for: try model.denyLease(requestID, reply: reply ?? "")).state
    }
}

/// U3: the menu bar window over every lease and the import status.
@available(macOS 26.0, *)
@MainActor
public final class LeaseMenuBarBackend: MacMenuBarBackend {
    private let model: MirrorAppModel

    public init(model: MirrorAppModel) {
        self.model = model
    }

    /// Local leases and, from the relay, remote requests and leases.
    public func snapshot() -> MacMenuBarSnapshot {
        let relay = model.relayApprover.update
        let remoteLeaseIDs = Set(relay.leases.map(\.lease.leaseID))
        let remoteWaiting = relay.requests
            .filter { $0.lease.state == .pending && !remoteLeaseIDs.contains($0.lease.leaseID) }
            .map { RelayScreenMapping.accessRequest($0, answered: nil) }
        return MacMenuBarSnapshot(
            requests: model.leaseStore.leases.map(model.accessRequest(for:)) + remoteWaiting
                + relay.leases.map(RelayScreenMapping.accessRequest),
            passwords: model.status.map { ImportedPasswords(count: $0.credentialItemCount, importedAt: $0.importedAt) },
            enrolments: relay.enrolments.map(RelayScreenMapping.enrolment)
                + relay.approverPairings.map(RelayScreenMapping.enrolment),
            relay: RelayScreenMapping.relayLink(relay),
            queuedAnswers: relay.queuedAnswerCount)
    }

    public func updates() -> AsyncStream<MacMenuBarSnapshot> {
        let backend = self
        return stream(Observations { backend.snapshot() })
    }

    public func endAccess(requestID: String) async throws -> AccessRequestState {
        let relay = model.relayApprover
        if relay.leases.contains(where: { $0.lease.leaseID == requestID }) {
            try await screenErrors { try await relay.revokeLease(requestID) }
            return .ended(at: .now)
        }
        return model.accessRequest(for: try model.leaseStore.revoke(requestID)).state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        let relay = model.relayApprover
        if let remote = relay.leases.first(where: { $0.lease.leaseID == requestID }) {
            try await screenErrors {
                try await relay.clearDenial(loginID: remote.lease.loginID, recipientID: remote.lease.recipient.recipientID)
            }
            return .denied(by: .mac, reply: nil, askAgainAfter: nil)
        }
        let lease = try model.leaseStore.get(requestID)
        try model.leaseStore.clearDenial(loginID: lease.loginID)
        return model.accessRequest(for: try model.leaseStore.get(requestID)).state
    }
}

/// U3: the rules window over the existing access-rules controller, keeping
/// its Touch ID confirmation. "Last used" is the last approval in the lease store.
@available(macOS 26.0, *)
@MainActor
public final class AccessRulesBackend: LoginRulesBackend {
    private let model: MirrorAppModel
    private var controller: CredentialAccessController { model.accessControl }

    public init(model: MirrorAppModel) {
        self.model = model
    }

    public func snapshot() -> LoginRulesSnapshot {
        let lastApproved = Dictionary(
            model.leaseStore.leases.filter { $0.approvedAtUnixSeconds > 0 }
                .map { ($0.loginID, Date(timeIntervalSince1970: TimeInterval($0.approvedAtUnixSeconds))) },
            uniquingKeysWith: max)
        let rows = controller.rows.map { row in
            LoginRuleRow(id: row.id, site: row.website.isEmpty ? row.title : row.website, account: row.account,
                rule: LoginRule(row.policy), lastUsed: lastApproved[row.id.uuidString])
        }
        return LoginRulesSnapshot(rows: rows, confirmation: confirmation(rows),
            isApplying: model.relayApprover.needsPublication)
    }

    public func updates() -> AsyncStream<LoginRulesSnapshot> {
        let backend = self
        return stream(Observations { backend.snapshot() })
    }

    public func setRule(_ rule: LoginRule, for loginIDs: Set<UUID>) async throws {
        await controller.setPolicy(CredentialAccessPolicy(rule), for: loginIDs)
        if let message = controller.errorMessage { throw RulesFailure(message: message) }
    }

    public func confirmRules() async throws {
        await controller.confirmRules()
        if controller.needsConfirmation { throw RulesFailure(message: controller.errorMessage ?? "Touch ID didn't confirm.") }
    }

    private func confirmation(_ rows: [LoginRuleRow]) -> RulesConfirmation? {
        guard controller.needsConfirmation, controller.hasLoadedLoginList else { return nil }
        func count(_ rule: LoginRule) -> Int { rows.lazy.filter { $0.rule == rule }.count }
        var summary = "\(rows.count) logins: \(count(.ask)) Ask, \(count(.automatic)) Automatic, \(count(.blocked)) Blocked."
        if controller.pendingPhoneBlockCount > 0 {
            summary += " \(controller.pendingPhoneBlockCount) blocked from your iPhone."
        }
        return RulesConfirmation(summary: summary,
            savedRulesWereUnreadable: controller.confirmationResetsUnreadableRules)
    }
}

struct RulesFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension LoginRule {
    init(_ policy: CredentialAccessPolicy) {
        switch policy {
        case .ask: self = .ask
        case .allowAutomatically: self = .automatic
        case .block: self = .blocked
        }
    }
}

extension CredentialAccessPolicy {
    init(_ rule: LoginRule) {
        switch rule {
        case .ask: self = .ask
        case .automatic: self = .allowAutomatically
        case .blocked: self = .block
        }
    }
}

/// Every value an observation produces, as a stream.
@MainActor
func stream<Element: Sendable>(_ observations: Observations<Element, Never>) -> AsyncStream<Element> {
    AsyncStream { continuation in
        let task = Task { @MainActor in
            for await value in observations { continuation.yield(value) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// One request's values, ending once it reaches a final state.
@MainActor
func streamUntilFinal(_ observations: Observations<AccessRequest?, Never>) -> AsyncStream<AccessRequest> {
    AsyncStream { continuation in
        let task = Task { @MainActor in
            for await request in observations {
                guard let request else { continue }
                continuation.yield(request)
                if !request.state.isWaitingForYou && !request.state.isInUse { break }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
#endif
