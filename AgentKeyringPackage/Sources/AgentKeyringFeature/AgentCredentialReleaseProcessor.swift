import Foundation

@MainActor
public struct AgentCredentialReleaseProcessor {
    private let bridge: AgentBridgeDirectory
    private let accessControl: CredentialAccessController
    private let approvals: CredentialApprovalCoordinator
    private let grants: CredentialApprovalGrants
    private let resolver: CredentialResolver

    public init(
        bridge: AgentBridgeDirectory,
        accessControl: CredentialAccessController,
        resolver: CredentialResolver = CredentialResolver(),
        grants: CredentialApprovalGrants = CredentialApprovalGrants(),
        approvals: CredentialApprovalCoordinator = CredentialApprovalCoordinator()
    ) {
        self.bridge = bridge
        self.accessControl = accessControl
        self.resolver = resolver
        self.grants = grants
        self.approvals = approvals
    }

    public func release(
        request: AgentBridgeRequest,
        generation: MirrorGeneration,
        onProgress: @escaping (AgentApprovalProgress) -> Void = { _ in },
        authorize: @escaping @MainActor (CredentialReleaseAuthorizationRequest, @escaping () -> Void) async throws -> Void,
        copyNative: (String, TimeInterval) -> Void
    ) async throws -> AgentBridgeResponse {
        guard request.action == .copy || request.action == .acquire else {
            throw AgentBridgeFailure(.invalidRequest, "A credential release action is required.")
        }
        try ensureRequestHasNotExpired(request)
        await accessControl.refresh(from: generation)
        let mirror = AgentMirrorSummary(
            importedAt: generation.createdAt,
            ageSeconds: max(0, Int(Date().timeIntervalSince(generation.createdAt))),
            credentialCount: generation.safeStatus.credentialItemCount
        )
        guard let targetURL = request.targetURL, let field = request.field else {
            throw AgentBridgeFailure(
                .invalidRequest, "The release request needs a target URL and field.")
        }
        try resolver.validateSecureTarget(targetURL)
        let candidates = try resolver.candidates(
            in: generation,
            targetURL: targetURL,
            usernameHint: request.usernameHint
        )
        guard !candidates.isEmpty else { throw CredentialResolverError.notFound }
        if request.candidateID == nil, candidates.count > 1 {
            return AgentBridgeResponse(
                id: request.id,
                ok: false,
                error: .ambiguous,
                message: CredentialResolverError.ambiguous.localizedDescription,
                mirror: mirror,
                candidates: candidates
            )
        }

        let selected: CredentialCandidate
        if let candidateID = request.candidateID {
            guard let candidate = candidates.first(where: { $0.id == candidateID }) else {
                throw CredentialResolverError.notFound
            }
            selected = candidate
        } else {
            guard let candidate = candidates.first else {
                throw CredentialResolverError.notFound
            }
            selected = candidate
        }
        guard selected.availableFields.contains(field) else {
            throw CredentialResolverError.fieldUnavailable
        }

        let releaseDecision = accessControl.releaseDecision(
            for: selected.id,
            field: field
        )
        if releaseDecision == .block {
            throw AgentBridgeFailure(
                .policyDenied,
                "Agent access to this credential is blocked in Agent Keyring."
            )
        }

        let needsApproval = releaseDecision == .requestAuthorization && !grants.contains(selected.id)
        if needsApproval {
            let approval = CredentialReleaseAuthorizationRequest(
                destination: approvalDestination(for: targetURL),
                account: selected.username ?? selected.title,
                field: field,
                credentialTitle: selected.title,
                expirationSeconds: request.action == .copy ? min(120, max(5, request.expirationSeconds)) : nil,
                authorizationDeadline: request.expiresAt
            )
            try await approvals.authorize(credentialID: selected.id, authorizationDeadline: request.expiresAt,
                onProgress: onProgress) { onPromptStarted in
                try await authorize(approval, onPromptStarted)
            }
        }

        try ensureRequestHasNotExpired(request)
        guard accessControl.releaseDecision(for: selected.id, field: field) != .block else {
            throw AgentBridgeFailure(.policyDenied,
                "Agent access to this credential is blocked in Agent Keyring.")
        }
        if needsApproval { grants.approve(selected.id) }
        let expiration = min(120, max(5, request.expirationSeconds))
        let secret = try resolver.secret(
            in: generation,
            targetURL: targetURL,
            usernameHint: request.usernameHint,
            candidateID: request.candidateID,
            field: field
        )
        if request.action == .acquire {
            let codeRecord = field == .totp
                ? generation.items.first(where: { $0.id == selected.id })?.credentials.first(where: {
                    if case .totp = $0 { return true }
                    return false
                }) : nil
            try CredentialTransfer.publish(secret, requestID: request.id,
                credentialID: selected.id, expiresAfter: 300, codeRecord: codeRecord)
        } else {
            copyNative(secret, TimeInterval(expiration))
        }
        return AgentBridgeResponse(
            id: request.id,
            ok: true,
            mirror: mirror,
            candidates: [selected],
            copiedField: field,
            clipboardExpiresAt: request.action == .copy
                ? Date().addingTimeInterval(TimeInterval(expiration)) : nil
        )
    }

    private func ensureRequestHasNotExpired(_ request: AgentBridgeRequest) throws {
        guard request.version == 1,
            request.createdAt.timeIntervalSinceNow <= 5,
            request.expiresAt > Date(),
            bridge.requestMatches(request)
        else {
            throw AgentBridgeFailure(.requestExpired, "The credential request is no longer active.")
        }
    }

    private func approvalDestination(for targetURL: String) -> String {
        guard let components = URLComponents(string: targetURL), let host = components.host
        else { return "the requested site" }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
    }
}

public struct AgentBridgeFailure: Error, Sendable {
    public let code: AgentBridgeErrorCode
    public let message: String

    public init(_ code: AgentBridgeErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
