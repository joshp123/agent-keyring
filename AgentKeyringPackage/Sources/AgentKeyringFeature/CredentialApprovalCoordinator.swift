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
    private var macPromptOwner: UUID?
    private var macPromptQueue: [UUID] = []
    private var macPromptWakeups: [UUID: () -> Void] = [:]

    private let lockState: any CredentialSessionLockState
    private let phoneChannel: (any IPhoneApprovalChannel)?
    private let pairedDevices: any PairedDevicePublicKeyProviding
    private let verifier: ApprovalDecisionVerifier
    private let phoneDelay: () -> TimeInterval
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void

    public init(
        lockState: any CredentialSessionLockState = SystemCredentialSessionLockState(),
        phoneChannel: (any IPhoneApprovalChannel)? = nil,
        pairedDevices: any PairedDevicePublicKeyProviding = CredentialAccessPolicyStore(),
        verifier: ApprovalDecisionVerifier? = nil,
        phoneDelay: @escaping () -> TimeInterval = { 120 },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.lockState = lockState
        self.phoneChannel = phoneChannel
        self.pairedDevices = pairedDevices
        self.verifier = verifier ?? ApprovalDecisionVerifier(pairedDevices: pairedDevices)
        self.phoneDelay = phoneDelay
        self.now = now
        self.sleep = sleep
    }

    public func authorize(
        credentialID: UUID,
        action: AgentBridgeAction = .acquire,
        authorizationDeadline: Date,
        approvalRequest: ApprovalRequest,
        cancelPrompt: @escaping () -> Void = {},
        onBlockLogin: @escaping () -> Void = {},
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
                    approvalRequest: approvalRequest, cancelPrompt: cancelPrompt, onBlockLogin: onBlockLogin,
                    onProgress: onProgress, prompt: prompt)
            }
            return
        }
        let progress = AgentApprovalProgress(waitingSince: now(),
            phase: lockState.isLocked && phoneChannel == nil ? .waitingForUnlock : .awaitingApproval)
        let approvalID = UUID()
        let approval = Task { @MainActor in
            try await self.route(scope: scope, authorizationDeadline: authorizationDeadline,
                approvalRequest: approvalRequest, cancelPrompt: cancelPrompt,
                onBlockLogin: onBlockLogin, prompt: prompt)
        }
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

    private enum RoutingEvent {
        case tick
        case mac(Result<Void, Error>, UUID)
        case phone(ApprovalDecision)
    }

    private func route(scope: CredentialApprovalScope, authorizationDeadline: Date,
        approvalRequest request: ApprovalRequest, cancelPrompt: @escaping () -> Void,
        onBlockLogin: @escaping () -> Void,
        prompt: @escaping @MainActor (@escaping () -> Void) async throws -> Void) async throws {
        let phone: (any IPhoneApprovalChannel)?
        if let phoneChannel, !(try await pairedDevices.pairedDevicePublicKeys()).isEmpty {
            phone = phoneChannel
        } else { phone = nil }
        if phone == nil || !lockState.isLocked { macPromptQueue.append(request.id) }
        let (events, continuation) = AsyncStream<RoutingEvent>.makeStream()
        var macAttempt: UUID?
        var macTask: Task<Void, Never>?
        var phoneTask: Task<Void, Never>?
        var phoneAsked = false
        var phoneScheduledAt: Date?
        var ticker: Task<Void, Never>?

        func refreshTicker() {
            let needed = self.lockState.isLocked || (!phoneAsked && phoneScheduledAt != nil)
            if !needed { ticker?.cancel(); ticker = nil; return }
            guard ticker == nil else { return }
            ticker = Task { @MainActor in
                do {
                    while !Task.isCancelled {
                        try await self.sleep(.milliseconds(250))
                        guard !Task.isCancelled else { return }
                        continuation.yield(.tick)
                        await Task.yield()
                    }
                } catch { }
            }
        }

        func stopMac() {
            guard macAttempt != nil else { return }
            macAttempt = nil
            macTask?.cancel()
            macTask = nil
            cancelPrompt()
            phoneScheduledAt = nil
            if phone != nil { self.macPromptQueue.removeAll { $0 == request.id } }
            self.releaseMacPrompt(requestID: request.id)
        }

        let deadlineTask = Task { @MainActor in
            do {
                try await self.sleep(.seconds(max(0, authorizationDeadline.timeIntervalSince(self.now()))))
                guard !Task.isCancelled else { return }
                continuation.yield(.tick)
            } catch { }
        }
        let lockChanges = lockState.changes
        let lockMonitor = Task { @MainActor in
            for await _ in lockChanges { continuation.yield(.tick) }
        }
        macPromptWakeups[request.id] = { continuation.yield(.tick) }
        defer {
            macPromptQueue.removeAll { $0 == request.id }
            macPromptWakeups.removeValue(forKey: request.id)
            stopMac()
            ticker?.cancel()
            deadlineTask.cancel()
            lockMonitor.cancel()
            phoneTask?.cancel()
            if phoneAsked {
                phone?.cancel(requestID: request.id)
                Task { await self.verifier.discard(requestID: request.id) }
            }
            continuation.finish()
        }

        func startMac() {
            if !macPromptQueue.contains(request.id) { macPromptQueue.append(request.id) }
            guard macPromptOwner == nil, macPromptQueue.first == request.id else { return }
            macPromptOwner = request.id
            let attempt = UUID()
            macAttempt = attempt
            macTask = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    guard !self.lockState.isLocked else { throw CredentialReleaseAuthorizationError.interrupted }
                    try await prompt {
                        guard macAttempt == attempt, !Task.isCancelled else { return }
                        let askedAt = self.now()
                        phoneScheduledAt = phone == nil || phoneAsked ? nil : askedAt.addingTimeInterval(self.phoneDelay())
                        self.recordProgress(scope: scope, askedAt: askedAt, phase: .awaitingApproval,
                            provider: phone == nil ? nil : .mac, phoneScheduledAt: phoneScheduledAt)
                        refreshTicker()
                    }
                    guard !Task.isCancelled else { return }
                    continuation.yield(.mac(.success(()), attempt))
                } catch {
                    guard !Task.isCancelled else { return }
                    continuation.yield(.mac(.failure(error), attempt))
                }
            }
        }

        func startPhone() async throws {
            guard let phone, !phoneAsked else { return }
            try await verifier.register(request)
            phoneAsked = true
            let decisions = phone.publish(request)
            recordProgress(scope: scope, askedAt: now(), phase: .awaitingApproval,
                provider: .iPhone, macWasLocked: lockState.isLocked, macWasAsleep: lockState.isDisplayAsleep)
            phoneTask = Task { @MainActor in
                for await decision in decisions {
                    guard !Task.isCancelled else { return }
                    continuation.yield(.phone(decision))
                }
            }
        }

        func updateRouting() async throws {
            if self.lockState.isLocked {
                stopMac()
                if phone == nil, self.pending[scope]?.progress.phase != .waitingForUnlock {
                    self.recordProgress(scope: scope, askedAt: nil, phase: .waitingForUnlock)
                }
                try await startPhone()
            } else {
                if macAttempt == nil { startMac() }
                if phoneScheduledAt.map({ self.now() >= $0 }) == true { try await startPhone() }
            }
            refreshTicker()
        }

        guard now() < authorizationDeadline else { throw CredentialReleaseAuthorizationError.expired }
        try await updateRouting()
        for await event in events {
            guard now() < authorizationDeadline else { throw CredentialReleaseAuthorizationError.expired }
            try await updateRouting()
            switch event {
            case .tick: break
            case let .mac(result, attempt):
                guard macAttempt == attempt else { continue }
                try result.get()
                if phone != nil { recordApproval(scope: scope, provider: .mac) }
                return
            case let .phone(decision):
                guard decision.requestID == request.id else { continue }
                let choice: ApprovalChoice
                do { choice = try await verifier.verify(decision) }
                catch { continue } // The verifier logs its fixed refusal reason without login data.
                switch choice {
                case .approve:
                    recordApproval(scope: scope, provider: .iPhone)
                    return
                case .deny: throw CredentialReleaseAuthorizationError.denied
                case .blockThisLogin:
                    onBlockLogin()
                    throw CredentialReleaseAuthorizationError.denied
                }
            }
        }
        throw CredentialReleaseAuthorizationError.expired
    }

    private func releaseMacPrompt(requestID: UUID) {
        guard macPromptOwner == requestID else { return }
        macPromptOwner = nil
        if let next = macPromptQueue.first { macPromptWakeups[next]?() }
    }

    private func recordApproval(scope: CredentialApprovalScope, provider: ApprovalPromptProvider) {
        guard var approval = pending[scope] else { return }
        let progress = approval.progress
        approval.progress = AgentApprovalProgress(waitingSince: progress.waitingSince,
            askedAt: progress.askedAt, phase: progress.phase, provider: progress.provider,
            phoneScheduledAt: progress.phoneScheduledAt, macWasLocked: progress.macWasLocked, macWasAsleep: progress.macWasAsleep,
            approvedAt: now(), approvedOn: provider)
        pending[scope] = approval
        for observer in approval.observers { observer(approval.progress) }
    }

    private func recordProgress(scope: CredentialApprovalScope, askedAt: Date?, phase: AgentApprovalPhase,
        provider: ApprovalPromptProvider? = nil, phoneScheduledAt: Date? = nil,
        macWasLocked: Bool? = nil, macWasAsleep: Bool? = nil) {
        guard var approval = pending[scope] else { return }
        approval.progress = AgentApprovalProgress(waitingSince: approval.progress.waitingSince,
            askedAt: askedAt, phase: phase, provider: provider, phoneScheduledAt: phoneScheduledAt,
            macWasLocked: macWasLocked, macWasAsleep: macWasAsleep)
        pending[scope] = approval
        for observer in approval.observers { observer(approval.progress) }
    }
}
