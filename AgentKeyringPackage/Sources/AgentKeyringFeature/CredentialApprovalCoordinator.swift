import Foundation

@MainActor
public final class CredentialApprovalCoordinator {
    private var pending: [UUID: Task<Void, Error>] = [:]

    public init() {}

    public func authorize(
        credentialID: UUID,
        prompt: @escaping @MainActor () async throws -> Void
    ) async throws {
        if let approval = pending[credentialID] {
            try await approval.value
            return
        }
        let approval = Task { @MainActor in try await prompt() }
        pending[credentialID] = approval
        defer { pending.removeValue(forKey: credentialID) }
        try await approval.value
    }
}
