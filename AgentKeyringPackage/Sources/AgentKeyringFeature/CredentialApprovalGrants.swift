import Foundation
import Observation

public struct CredentialApprovalScope: Hashable, Sendable {
    public let credentialID: UUID
    public let action: AgentBridgeAction
    public let requesterIdentity: VerifiedRequesterIdentity?
    let unverifiedRequestID: UUID?

    init(credentialID: UUID, action: AgentBridgeAction, requesterIdentity: VerifiedRequesterIdentity?, unverifiedRequestID: UUID? = nil) {
        self.credentialID = credentialID
        self.action = action
        self.requesterIdentity = requesterIdentity
        self.unverifiedRequestID = unverifiedRequestID
    }
}

public struct ActiveCredentialApprovalGrant: Identifiable, Sendable {
    public let id: CredentialApprovalScope
    public let site: String
    public let account: String
    public let expiresAt: Date
}

@MainActor
@Observable
public final class CredentialApprovalGrants {
    private var approvals: [CredentialApprovalScope: ActiveCredentialApprovalGrant] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var active: [ActiveCredentialApprovalGrant] {
        approvals.values.filter { $0.expiresAt > now() }.sorted {
            ($0.site, $0.account, $0.id.action.rawValue) < ($1.site, $1.account, $1.id.action.rawValue)
        }
    }

    public func contains(_ credentialID: UUID, action: AgentBridgeAction, requesterIdentity: VerifiedRequesterIdentity) -> Bool {
        let scope = CredentialApprovalScope(credentialID: credentialID, action: action, requesterIdentity: requesterIdentity)
        guard let approval = approvals[scope] else { return false }
        guard approval.expiresAt > now() else {
            approvals.removeValue(forKey: scope)
            return false
        }
        return true
    }

    public func approve(_ credentialID: UUID, action: AgentBridgeAction, requesterIdentity: VerifiedRequesterIdentity, site: String, account: String) {
        let scope = CredentialApprovalScope(credentialID: credentialID, action: action, requesterIdentity: requesterIdentity)
        approvals[scope] = ActiveCredentialApprovalGrant(id: scope, site: site, account: account,
            expiresAt: now().addingTimeInterval(30 * 60))
    }

    public func end(_ scope: CredentialApprovalScope) {
        approvals.removeValue(forKey: scope)
    }

    public func endAll() {
        approvals.removeAll()
    }
}
