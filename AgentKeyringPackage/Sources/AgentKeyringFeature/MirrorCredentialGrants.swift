import AgentKeyringProtocol
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func endAllGrants() {
        do { for lease in leaseStore.leases where !lease.state.isTerminal { try leaseStore.revoke(lease.leaseID) } }
        catch { problem = MessageCopy.leasesNotEnded }
    }

    /// Josh clicked Approve: macOS's dialog asks for Touch ID or the Watch,
    /// and the same context then opens this Mac's sealed copy of the login.
    @discardableResult
    public func approveLeaseWithTouchID(_ leaseID: String, context: LAContext,
        onAuthenticated: @MainActor () -> Void = {}) async throws -> Agentkeyring_V1_Lease {
        guard !isApprovingLease else { throw LeaseFailure(.conflict, MessageCopy.alreadyApproving) }
        isApprovingLease = true
        defer { isApprovingLease = false }
        let lease = try leaseStore.get(leaseID)
        guard lease.state == .pending else { return lease }
        guard let login = leaseLogins.first(where: { $0.id.uuidString == lease.loginID }) else {
            throw LeaseFailure(.notFound, MessageCopy.passwordGone)
        }
        let reason = MessageCopy.useYourPassword(site: login.origins.first ?? login.title, account: login.username ?? login.title,
            agent: leaseStore.requester(for: leaseID)?.name ?? lease.recipient.clientLabel)
        let copy = try await macCopy(of: lease.loginID)
        try await OwnerConfirmation.confirm(context, reason: reason,
            until: Date(timeIntervalSince1970: TimeInterval(lease.pendingUntilUnixSeconds)))
        try Task.checkCancellation()
        // A rule may have changed while the dialog was up.
        guard accessControl.policy(for: login.id) != .block else { throw LeaseFailure(.permissionDenied, MessageCopy.passwordBlocked) }
        let secret = try macKeys().open(copy, context: context)
        try checkShown(secret, as: login)
        onAuthenticated()
        return try leaseStore.approve(leaseID, secret: secret)
    }

    @discardableResult
    public func denyLease(_ leaseID: String, reply: String = "") throws -> Agentkeyring_V1_Lease {
        try leaseStore.deny(leaseID, reply: reply)
    }
}
