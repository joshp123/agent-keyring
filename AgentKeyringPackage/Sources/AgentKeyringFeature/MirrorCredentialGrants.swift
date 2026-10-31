import AgentKeyringProtocol
import Foundation

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func endAllGrants() {
        do { for lease in leaseStore.leases where !lease.state.isTerminal { try leaseStore.revoke(lease.leaseID) } }
        catch { notice = MirrorNotice(kind: .error, text: "The leases could not be ended.") }
    }

    /// U2 supplies its own panel and calls this on Approve. It can turn off the
    /// transitional system prompt with automaticallyPromptForLeases = false.
    @discardableResult
    public func approveLeaseWithTouchID(_ leaseID: String) async throws -> Agentkeyring_V1_Lease {
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
        let purpose: String = switch lease.purpose {
        case .browserSignIn: "Browser sign-in for this task, up to 30 minutes"
        case .program: "Give the password to \(lease.program.executable) for this task, up to 30 minutes"
        case .agentProcess: "Give the password to the agent's own code for this task, up to 30 minutes"
        default: ""
        }
        let approval = CredentialReleaseAuthorizationRequest(destination: login.origins.first ?? login.title,
            account: login.username ?? login.title, field: .password, credentialTitle: login.title,
            expirationSeconds: 1800, authorizationDeadline: Date(timeIntervalSince1970: TimeInterval(lease.pendingUntilUnixSeconds)),
            leaseDescription: purpose + ". Agent's reason: “\(lease.reason)”")
        try await authorizer.authorize(approval, onPromptStarted: {})
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
