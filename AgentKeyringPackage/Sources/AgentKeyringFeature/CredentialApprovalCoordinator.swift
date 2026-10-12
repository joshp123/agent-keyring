import Foundation

@MainActor
public final class CredentialApprovalCoordinator {
    private struct PendingApproval {
        let id: UUID
        let authorizationDeadline: Date
        let task: Task<Void, Error>
        var progress: AgentApprovalProgress
        var observers: [(AgentApprovalProgress) -> Void]
    }
    private var pending: [CredentialApprovalScope: PendingApproval] = [:]
    private var lastApprovalTask: Task<Void, Error>?

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
        action: AgentBridgeAction = .acquire,
        authorizationDeadline: Date,
        onProgress: @escaping (AgentApprovalProgress) -> Void = { _ in },
        prompt: @escaping @MainActor (@escaping () -> Void) async throws -> Void
    ) async throws {
        let scope = CredentialApprovalScope(credentialID: credentialID, action: action)
        if let approval = pending[scope] {
            pending[scope]?.observers.append(onProgress)
            onProgress(approval.progress)
            do {
                try await approval.task.value
            } catch CredentialReleaseAuthorizationError.expired {
                guard now() < authorizationDeadline,
                    approval.authorizationDeadline < authorizationDeadline else {
                    throw CredentialReleaseAuthorizationError.expired
                }
                removePendingApproval(scope: scope, approvalID: approval.id)
                try await authorize(credentialID: credentialID, action: action, authorizationDeadline: authorizationDeadline,
                    onProgress: onProgress, prompt: prompt)
            }
            return
        }
        let progress = AgentApprovalProgress(waitingSince: now(),
            phase: lockState.isLocked ? .waitingForUnlock : .awaitingApproval)
        let approvalID = UUID()
        let precedingApproval = lastApprovalTask
        let approval = Task { @MainActor in
            if let precedingApproval { _ = await precedingApproval.result }
            while self.lockState.isLocked {
                guard self.now() < authorizationDeadline else {
                    throw CredentialReleaseAuthorizationError.expired
                }
                try await self.sleep(.milliseconds(250))
            }
            guard self.now() < authorizationDeadline else {
                throw CredentialReleaseAuthorizationError.expired
            }
            try await prompt { self.recordPromptStarted(scope: scope) }
        }
        lastApprovalTask = approval
        pending[scope] = PendingApproval(id: approvalID, authorizationDeadline: authorizationDeadline,
            task: approval, progress: progress, observers: [onProgress])
        onProgress(progress)
        defer { removePendingApproval(scope: scope, approvalID: approvalID) }
        try await approval.value
    }

    private func removePendingApproval(scope: CredentialApprovalScope, approvalID: UUID) {
        guard pending[scope]?.id == approvalID else { return }
        pending.removeValue(forKey: scope)
    }

    private func recordPromptStarted(scope: CredentialApprovalScope) {
        guard var approval = pending[scope] else { return }
        approval.progress = AgentApprovalProgress(waitingSince: approval.progress.waitingSince,
            askedAt: now(), phase: .awaitingApproval)
        pending[scope] = approval
        for observer in approval.observers { observer(approval.progress) }
    }
}
