import AgentKeyringProtocol
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func resetLeaseHistory() async throws {
        guard leaseStore.needsHistoryReset else { return }
        let context = LAContext()
        defer { context.invalidate() }
        let cancelEvaluation: @MainActor @Sendable () -> Void = { context.invalidate() }
        let confirmed = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion,
                localizedReason: "reset its record of what agents are using on this Mac. Your logins and rules stay")
        } onCancel: { Task { @MainActor in cancelEvaluation() } }
        try Task.checkCancellation()
        guard confirmed else { throw CancellationError() }
        try leaseStore.resetHistoryAfterOwnerConfirmation()
        await loadStatus()
    }

    public func endAllGrants() {
        do { for lease in leaseStore.leases where !lease.state.isTerminal { try leaseStore.revoke(lease.leaseID) } }
        catch { notice = MirrorNotice(kind: .error, text: "The leases could not be ended.") }
    }

    /// U2 supplies its own panel and calls this on Approve. It can turn off the
    /// transitional system prompt with automaticallyPromptForLeases = false.
    @discardableResult
    public func approveLeaseWithTouchID(_ leaseID: String) async throws -> Agentkeyring_V1_Lease {
        try await approveLease(leaseID) { [authorizer] approval in
            try await authorizer.authorize(approval, onPromptStarted: {})
        }
    }

    /// The panel owns this context and displays its biometric controls. The
    /// authority evaluates that exact context without activating another UI.
    @discardableResult
    public func approveLeaseWithTouchID(_ leaseID: String, context: LAContext) async throws -> Agentkeyring_V1_Lease {
        let panelAuthorizer = LocalCredentialReleaseAuthorizer()
        return try await approveLease(leaseID) { approval in
            try await panelAuthorizer.authorize(approval, context: context, onPromptStarted: {})
        }
    }

    private func approveLease(_ leaseID: String,
        authorize: (CredentialReleaseAuthorizationRequest) async throws -> Void) async throws -> Agentkeyring_V1_Lease {
        guard !isApprovingLease else { throw LeaseFailure(.conflict, "An approval is already in progress on this Mac.") }
        isApprovingLease = true
        defer { isApprovingLease = false }
        try await refreshLeasePolicy()
        try Task.checkCancellation()
        let lease = try leaseStore.get(leaseID)
        guard lease.state == .pending else { return lease }
        guard let login = leaseLogins.first(where: { $0.id.uuidString == lease.loginID }) else {
            throw LeaseFailure(.notFound, "The login is no longer available.")
        }
        let site = login.origins.first ?? login.title
        let account = login.username ?? login.title
        let reason = CredentialReleaseAuthorizationRequest.leaseReason(purpose: lease.purpose, site: site,
            account: account, program: lease.program.executable,
            agent: leaseStore.requester(for: leaseID)?.name ?? lease.recipient.clientLabel)
        let approval = CredentialReleaseAuthorizationRequest(destination: login.origins.first ?? login.title,
            account: login.username ?? login.title, field: .password, credentialTitle: login.title,
            expirationSeconds: 1800, authorizationDeadline: Date(timeIntervalSince1970: TimeInterval(lease.pendingUntilUnixSeconds)),
            leaseDescription: reason)
        try await authorize(approval)
        try Task.checkCancellation()
        // Re-read signed rules after the suspension and reject a late answer.
        try await refreshLeasePolicy()
        try Task.checkCancellation()
        return try leaseStore.approve(leaseID)
    }

    @discardableResult
    public func denyLease(_ leaseID: String, reply: String = "") throws -> Agentkeyring_V1_Lease {
        try leaseStore.deny(leaseID, reply: reply)
    }

    func startPendingMacApprovals() {
        guard automaticallyPromptForLeases, macApprovalTask == nil else { return }
        macApprovalTask = Task { [weak self] in
            guard let self else { return }
            defer { self.macApprovalTask = nil }
            while self.automaticallyPromptForLeases,
                let lease = self.leaseStore.waitingRequests.last(where: { !self.attemptedMacApprovals.contains($0.leaseID) }) {
                self.attemptedMacApprovals.insert(lease.leaseID)
                do { try await self.approveLeaseWithTouchID(lease.leaseID) }
                catch { self.notice = MirrorNotice(kind: .information, text: "Approval could not finish. The request is still available in Agent Keyring.") }
            }
        }
    }
}
