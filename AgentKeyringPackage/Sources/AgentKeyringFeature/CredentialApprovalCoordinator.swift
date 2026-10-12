import Foundation

@MainActor
public final class CredentialApprovalCoordinator {
    private struct PendingApproval {
        let task: Task<Void, Error>
        var progress: AgentApprovalProgress
        var observers: [(AgentApprovalProgress) -> Void]
    }
    private var pending: [UUID: PendingApproval] = [:]

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
        onProgress: @escaping (AgentApprovalProgress) -> Void = { _ in },
        prompt: @escaping @MainActor () async throws -> Void
    ) async throws {
        if let approval = pending[credentialID] {
            pending[credentialID]?.observers.append(onProgress)
            onProgress(approval.progress)
            try await approval.task.value
            return
        }
        let progress = AgentApprovalProgress(askedAt: now(),
            phase: lockState.isLocked ? .waitingForUnlock : .awaitingApproval)
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
            self.updateProgress(credentialID: credentialID, phase: .awaitingApproval)
            try await prompt()
        }
        pending[credentialID] = PendingApproval(task: approval, progress: progress, observers: [onProgress])
        onProgress(progress)
        defer { pending.removeValue(forKey: credentialID) }
        try await approval.value
    }

    private func updateProgress(credentialID: UUID, phase: AgentApprovalPhase) {
        guard var approval = pending[credentialID], approval.progress.phase != phase else { return }
        approval.progress = AgentApprovalProgress(askedAt: approval.progress.askedAt, phase: phase)
        pending[credentialID] = approval
        for observer in approval.observers { observer(approval.progress) }
    }
}
