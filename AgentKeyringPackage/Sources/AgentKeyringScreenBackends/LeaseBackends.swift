// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Mac screens' backends over the release 2 lease store (RFC 0007, U2 and
// U3). Plumbing only: approval, denial and revocation are the store's.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
extension MacKeyringEngine {
    /// The screen value for one lease, with its requester and login.
    @MainActor
    public func accessRequest(for lease: Agentkeyring_V2_Lease) -> AccessRequest {
        LeaseScreenMapping.accessRequest(lease, requester: leaseStore.requester(for: lease.requestID),
            login: leaseLogins.first { $0.id.uuidString == lease.loginID })
    }
}

/// U2: the approval panel answers through the store. Approving asks for
/// Touch ID or the Watch in macOS's own dialog; the same context then opens
/// the login and signs the answer.
@available(macOS 26.0, *)
@MainActor
public final class LeaseApprovalBackend: MacApprovalBackend {
    private let model: MacKeyringEngine
    private var contexts: [String: LAContext] = [:]

    public init(model: MacKeyringEngine) {
        self.model = model
    }

    public func accessRequestUpdates(requestID: String) -> AsyncStream<AccessRequest> {
        let model = model
        return streamUntilFinal(Observations {
            model.leaseStore.leases.first { $0.requestID == requestID }.map(model.accessRequest(for:))
        })
    }

    public func approveAccessRequest(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
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

    public func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState {
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
    private let model: MacKeyringEngine

    public init(model: MacKeyringEngine) {
        self.model = model
    }

    /// This Mac's agents' leases, other computers' requests shown here, and
    /// computers and devices waiting to join.
    public func snapshot() -> MacMenuBarSnapshot {
        let device = model.device
        let remote = (device?.remoteAsks.values.map { RemoteRequestBackend.accessRequest($0, members: device?.members) } ?? []).map { request in
            // The asking computer may not say when its 30 minutes run out: past its time, it is no longer in use.
            var request = request
            if case let .approved(_, until) = request.state, until <= .now { request.state = .expired(at: until) }
            return request
        }
        return MacMenuBarSnapshot(
            requests: model.leaseStore.leases.map(model.accessRequest(for:)) + remote,
            enrolments: device?.joins.map(JoinScreenMapping.enrolment) ?? [],
            passwordCount: model.status?.credentialItemCount ?? 0)
    }

    public func menuBarSnapshotUpdates() -> AsyncStream<MacMenuBarSnapshot> {
        let backend = self
        return stream(Observations { backend.snapshot() })
    }

    public func endApprovedAccess(requestID: String) async throws -> AccessRequestState {
        if let device = model.device, device.remoteAsks[requestID] != nil {
            do { _ = try await device.stopRemote(requestID) } catch let failure as AgentRPCError { throw ScreenFailure(message: failure.message) }
            guard let ask = device.remoteAsks[requestID] else { throw ScreenFailure(message: MessageCopy.endsByItself) }
            return RemoteRequestBackend.accessRequest(ask, members: device.members).state
        }
        guard model.leaseStore.leases.contains(where: { $0.requestID == requestID }) else {
            throw ScreenFailure(message: MessageCopy.endsByItself)
        }
        return model.accessRequest(for: try model.leaseStore.revoke(requestID)).state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        let lease = try model.leaseStore.get(requestID)
        try model.leaseStore.clearDenial(loginID: lease.loginID)
        return model.accessRequest(for: try model.leaseStore.get(requestID)).state
    }

    public func approveAccessRequest(requestID: String) async throws -> AccessRequestState {
        let context = LAContext()
        defer { context.invalidate() }
        var resolved: AccessRequestState = .approved(by: .mac, until: .now.addingTimeInterval(RequestedAccess.longestLease))
        do {
            try await screenErrors {
                if let device = model.device, device.remoteAsks[requestID] != nil {
                    _ = try await device.approveRemote(requestID, context: context, onAuthenticated: {})
                    if let ask = device.remoteAsks[requestID] {
                        resolved = RemoteRequestBackend.accessRequest(ask, members: device.members).state
                    }
                    return
                }
                let lease = try await model.approveLeaseWithTouchID(requestID, context: context, onAuthenticated: {})
                resolved = model.accessRequest(for: lease).state
            }
            return resolved
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
    }

    public func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState {
        var resolved: AccessRequestState = .denied(by: .mac, reply: reply, askAgainAfter: nil)
        try await screenErrors {
            if let device = model.device, device.remoteAsks[requestID] != nil {
                _ = try await device.denyRemote(requestID, reply: reply ?? "")
                if let ask = device.remoteAsks[requestID] {
                    resolved = RemoteRequestBackend.accessRequest(ask, members: device.members).state
                }
                return
            }
            let lease = try model.denyLease(requestID, reply: reply ?? "")
            resolved = model.accessRequest(for: lease).state
        }
        return resolved
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
