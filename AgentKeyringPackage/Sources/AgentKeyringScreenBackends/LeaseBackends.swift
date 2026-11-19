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

/// U2: the approval panel answers through the store. Approving asks for
/// Touch ID or the Watch in macOS's own dialog; the same context then opens
/// the login and signs the answer.
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

    public func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        let context = LAContext()
        contexts[requestID] = context
        defer { if contexts[requestID] === context { contexts[requestID] = nil } }
        do {
            let lease = try await model.approveLeaseWithTouchID(requestID, context: context, onAuthenticated: onAuthenticated)
            return model.accessRequest(for: lease).state
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
    }

    public func cancelAuthentication(requestID: String) {
        contexts.removeValue(forKey: requestID)?.invalidate()
    }

    public func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        cancelAuthentication(requestID: requestID)
        return model.accessRequest(for: try model.denyLease(requestID, reply: reply ?? "")).state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        let lease = try model.leaseStore.get(requestID)
        try model.leaseStore.clearDenial(loginID: lease.loginID)
        return model.accessRequest(for: try model.leaseStore.get(requestID)).state
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

    /// Local leases and requests from agents on other machines.
    public func snapshot() -> MacMenuBarSnapshot {
        let device = model.device
        let remote = ((device.map { Array($0.waiting.values) + Array($0.finished.values) }) ?? []).compactMap { work in
            device.flatMap { RelayScreenMapping.accessRequest(work, device: $0, logins: model.leaseLogins) }
        }
        return MacMenuBarSnapshot(
            requests: model.leaseStore.leases.map(model.accessRequest(for:)) + remote,
            enrolments: device?.joins.map(RelayScreenMapping.enrolment) ?? [],
            relay: device?.isJoined == true || device?.setup != nil ? RelayScreenMapping.relayLink(device) : nil)
    }

    public func updates() -> AsyncStream<MacMenuBarSnapshot> {
        let backend = self
        return stream(Observations { backend.snapshot() })
    }

    public func endAccess(requestID: String) async throws -> AccessRequestState {
        guard model.leaseStore.leases.contains(where: { $0.leaseID == requestID }) else {
            throw ScreenFailure(message: "Access on another computer ends by itself 30 minutes after approval.")
        }
        return model.accessRequest(for: try model.leaseStore.revoke(requestID)).state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        let lease = try model.leaseStore.get(requestID)
        try model.leaseStore.clearDenial(loginID: lease.loginID)
        return model.accessRequest(for: try model.leaseStore.get(requestID)).state
    }
}

extension LoginRule {
    public init(_ policy: CredentialAccessPolicy) {
        switch policy {
        case .ask: self = .ask
        case .askOnPhone: self = .askOnPhone
        case .allowAutomatically: self = .automatic
        case .block: self = .blocked
        }
    }
}

extension CredentialAccessPolicy {
    init(_ rule: LoginRule) {
        switch rule {
        case .ask: self = .ask
        case .askOnPhone: self = .askOnPhone
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
