import Foundation

@MainActor
public final class CredentialApprovalCoordinator {
    private var pending: [UUID: Task<Void, Error>] = [:]

    private let lockState: any CredentialSessionLockState
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void

    public init(
        lockState: any CredentialSessionLockState = SystemCredentialSessionLockState(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.lockState = lockState
        self.now = now
        self.sleep = sleep
    }

    public func authorize(
        credentialID: UUID,
        authorizationDeadline: Date,
        prompt: @escaping @MainActor () async throws -> Void
    ) async throws {
        if let approval = pending[credentialID] {
            try await approval.value
            return
        }
        let approval = Task { @MainActor in
            while self.lockState.isLocked {
                guard self.now() < authorizationDeadline else {
                    throw CredentialReleaseAuthorizationError.expired
                }
                try await self.sleep(.milliseconds(250))
            }
            guard self.now() < authorizationDeadline else {
                throw CredentialReleaseAuthorizationError.expired
            }
            try await prompt()
        }
        pending[credentialID] = approval
        defer { pending.removeValue(forKey: credentialID) }
        try await approval.value
    }
}
