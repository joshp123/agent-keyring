#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MacKeyringEngine {
    func endAllGrants() {
        do { for lease in leaseStore.leases where !lease.state.isTerminal { try leaseStore.revoke(lease.requestID) } }
        catch { problem = MessageCopy.leasesNotEnded }
    }

    /// Josh clicked Approve: macOS's dialog asks for Touch ID or the Watch,
    /// and the same context then opens this Mac's sealed copy of the login.
    @discardableResult
    public func approveLeaseWithTouchID(_ leaseID: String, context: LAContext,
        onAuthenticated: @MainActor () -> Void = {}) async throws -> Agentkeyring_V2_Lease {
        guard !isApprovingLease else { throw AgentRPCError(.conflict, MessageCopy.alreadyApproving) }
        isApprovingLease = true
        defer { isApprovingLease = false }
        let lease = try leaseStore.get(leaseID)
        guard lease.state == .waiting else { return lease }
        guard let login = leaseLogins.first(where: { $0.id.uuidString == lease.loginID }) else {
            throw AgentRPCError(.notFound, MessageCopy.passwordGone)
        }
        let reason = MessageCopy.useYourPassword(site: login.origins.first ?? login.title, account: login.username ?? login.title,
            agent: leaseStore.requester(for: leaseID)?.name ?? lease.authorityContext.recipient.clientLabel)
        let copy = try await macCopy(of: lease.loginID)
        let keys = try macKeys()
        try await keys.confirmOwner(context, reason: reason,
            until: Date(timeIntervalSince1970: TimeInterval(lease.answerByUnixSeconds)))
        try Task.checkCancellation()
        // A rule may have changed while the dialog was up.
        guard accessControl.rule(for: login.id) != .blocked else { throw AgentRPCError(.permissionDenied, MessageCopy.passwordBlocked) }
        let secret = try macKeys().openSealedLogin(copy, context: context)
        try checkShown(secret, as: login)
        onAuthenticated()
        return try leaseStore.approve(leaseID, secret: secret)
    }

    @discardableResult
    public func denyLease(_ leaseID: String, reply: String = "") throws -> Agentkeyring_V2_Lease {
        try leaseStore.denyLease(leaseID, reply: reply)
    }
}
#endif
