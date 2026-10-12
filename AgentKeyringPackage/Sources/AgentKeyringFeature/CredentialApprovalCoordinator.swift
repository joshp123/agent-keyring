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
        approvalRequest: ApprovalRequest? = nil,
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
        let precedingApproval = lastApprovalTask
        let approval = Task { @MainActor in
            if let precedingApproval { _ = await precedingApproval.result }
            try await self.route(scope: scope, authorizationDeadline: authorizationDeadline,
                approvalRequest: approvalRequest, cancelPrompt: cancelPrompt,
                onBlockLogin: onBlockLogin, prompt: prompt)
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

    private enum RoutingEvent {
        case tick
        case mac(Result<ApprovalProviderResponse, Error>, UUID)
        case phone(ApprovalDecision)
    }

    private func route(scope: CredentialApprovalScope, authorizationDeadline: Date,
        approvalRequest: ApprovalRequest?, cancelPrompt: @escaping () -> Void,
        onBlockLogin: @escaping () -> Void,
        prompt: @escaping @MainActor (@escaping () -> Void) async throws -> Void) async throws {
        let request = try approvalRequest ?? ApprovalRequest(agentDisplayLabel: "Local agent",
            site: "", account: "", field: .password,
            action: scope.action == .fill ? .fill : .acquire, createdAt: now())
        let phone: IPhoneApprovalProvider?
        if let phoneChannel, approvalRequest != nil {
            phone = try await IPhoneApprovalProvider.paired(channel: phoneChannel, devices: pairedDevices)
        } else { phone = nil }
        if phone == nil, phoneChannel != nil, lockState.isLocked {
            recordProgress(scope: scope, askedAt: nil, phase: .waitingForUnlock)
        }
        let mac = MacApprovalProvider(prompt: prompt, cancelPrompt: cancelPrompt)
        let (events, continuation) = AsyncStream<RoutingEvent>.makeStream()
        var macAttempt: UUID?
        var macTask: Task<Void, Never>?
        var phoneTask: Task<Void, Never>?
        var phoneAsked = false
        var phoneScheduledAt: Date?
        let ticker = Task { @MainActor in
            do {
                while !Task.isCancelled {
                    try await self.sleep(.milliseconds(250))
                    guard !Task.isCancelled else { return }
                    continuation.yield(.tick)
                    await Task.yield()
                }
            } catch { continuation.finish() }
        }
        defer {
            ticker.cancel()
            macTask?.cancel()
            phoneTask?.cancel()
            if macAttempt != nil { mac.cancel(requestID: request.id) }
            if phoneAsked { phone?.cancel(requestID: request.id) }
            continuation.finish()
            if phoneAsked { Task { await self.verifier.discard(requestID: request.id) } }
        }

        func startMac() {
            let attempt = UUID()
            macAttempt = attempt
            let responses = mac.responses(to: request) {
                guard macAttempt == attempt else { return }
                let askedAt = self.now()
                phoneScheduledAt = phone == nil ? nil : askedAt.addingTimeInterval(self.phoneDelay())
                self.recordProgress(scope: scope, askedAt: askedAt, phase: .awaitingApproval,
                    provider: phone == nil ? nil : .mac, phoneScheduledAt: phoneScheduledAt)
            }
            macTask = Task { @MainActor in
                do {
                    for try await response in responses {
                        continuation.yield(.mac(.success(response), attempt))
                    }
                } catch { continuation.yield(.mac(.failure(error), attempt)) }
            }
        }

        func startPhone() async throws {
            guard let phone, !phoneAsked else { return }
            try await verifier.register(request)
            phoneAsked = true
            let responses = phone.responses(to: request) {
                self.recordProgress(scope: scope, askedAt: self.now(), phase: .awaitingApproval,
                    provider: .iPhone, macWasLocked: self.lockState.isLocked)
            }
            phoneTask = Task { @MainActor in
                do {
                    for try await response in responses {
                        if case let .iPhoneDecision(decision) = response { continuation.yield(.phone(decision)) }
                    }
                } catch { /* Channel failure leaves the request waiting until its deadline. */ }
            }
        }

        guard now() < authorizationDeadline else { throw CredentialReleaseAuthorizationError.expired }
        if lockState.isLocked { try await startPhone() }
        else { startMac() }
        for await event in events {
            guard now() < authorizationDeadline else { throw CredentialReleaseAuthorizationError.expired }
            switch event {
            case .tick:
                if macAttempt == nil, !lockState.isLocked, !phoneAsked { startMac() }
                if lockState.isLocked || (phoneScheduledAt.map { now() >= $0 } ?? false) {
                    try await startPhone()
                }
            case let .mac(result, attempt):
                guard macAttempt == attempt else { continue }
                _ = try result.get()
                return
            case let .phone(decision):
                let choice: ApprovalChoice
                do { choice = try await verifier.verify(decision) }
                catch { continue } // The verifier logs its fixed refusal reason without login data.
                switch choice {
                case .approve:
                    recordProgress(scope: scope, askedAt: pending[scope]?.progress.askedAt,
                        phase: .awaitingApproval, provider: .iPhone, approvedAt: now())
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

    private func recordProgress(scope: CredentialApprovalScope, askedAt: Date?, phase: AgentApprovalPhase,
        provider: ApprovalPromptProvider? = nil, phoneScheduledAt: Date? = nil,
        macWasLocked: Bool? = nil, approvedAt: Date? = nil) {
        guard var approval = pending[scope] else { return }
        approval.progress = AgentApprovalProgress(waitingSince: approval.progress.waitingSince,
            askedAt: askedAt, phase: phase, provider: provider, phoneScheduledAt: phoneScheduledAt,
            macWasLocked: macWasLocked, approvedAt: approvedAt)
        pending[scope] = approval
        for observer in approval.observers { observer(approval.progress) }
    }
}
