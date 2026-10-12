import Foundation

struct CredentialApprovalScope: Hashable {
    let credentialID: UUID
    let action: AgentBridgeAction
}

@MainActor
public final class CredentialApprovalGrants {
    private var expirations: [CredentialApprovalScope: Date] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func contains(_ credentialID: UUID, action: AgentBridgeAction) -> Bool {
        let scope = CredentialApprovalScope(credentialID: credentialID, action: action)
        guard let expiration = expirations[scope] else { return false }
        guard expiration > now() else {
            expirations.removeValue(forKey: scope)
            return false
        }
        return true
    }

    public func approve(_ credentialID: UUID, action: AgentBridgeAction) {
        expirations[CredentialApprovalScope(credentialID: credentialID, action: action)] = now().addingTimeInterval(30 * 60)
    }

    public func endAll() {
        expirations.removeAll()
    }
}
