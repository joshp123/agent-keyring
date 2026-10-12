import Foundation

@MainActor
public final class CredentialApprovalGrants {
    private var expirations: [UUID: Date] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func contains(_ credentialID: UUID) -> Bool {
        guard let expiration = expirations[credentialID] else { return false }
        guard expiration > now() else {
            expirations.removeValue(forKey: credentialID)
            return false
        }
        return true
    }

    public func approve(_ credentialID: UUID) {
        expirations[credentialID] = now().addingTimeInterval(30 * 60)
    }

    public func endAll() {
        expirations.removeAll()
    }
}
