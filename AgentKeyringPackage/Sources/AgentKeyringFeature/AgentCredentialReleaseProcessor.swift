import Foundation

@MainActor
public struct AgentCredentialReleaseProcessor {
    private let bridge: AgentBridgeDirectory
    private let accessControl: CredentialAccessController
    private let approvals: CredentialApprovalCoordinator
    private let grants: CredentialApprovalGrants
    private let filler: (any CredentialFiller)?
    private let now: () -> Date
    private let resolver: CredentialResolver
    private let possiblyStaleCredentialIDs: Set<UUID>

    public init(
        bridge: AgentBridgeDirectory,
        accessControl: CredentialAccessController,
        resolver: CredentialResolver = CredentialResolver(),
        grants: CredentialApprovalGrants = CredentialApprovalGrants(),
        approvals: CredentialApprovalCoordinator = CredentialApprovalCoordinator(),
        possiblyStaleCredentialIDs: Set<UUID> = [],
        filler: (any CredentialFiller)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.bridge = bridge
        self.accessControl = accessControl
        self.resolver = resolver
        self.grants = grants
        self.approvals = approvals
        self.filler = filler
        self.now = now
        self.possiblyStaleCredentialIDs = possiblyStaleCredentialIDs
    }

    public func release(
        request: AgentBridgeRequest,
        generation: MirrorGeneration,
        onProgress: @escaping (AgentApprovalProgress) -> Void = { _ in },
        authorize: @escaping @MainActor (CredentialReleaseAuthorizationRequest, @escaping () -> Void) async throws -> Void
    ) async throws -> AgentBridgeResponse {
        guard request.action == .acquire || request.action == .fill else {
            throw AgentBridgeFailure(.invalidRequest, "A credential release action is required.")
        }
        try ensureRequestHasNotExpired(request)
        await accessControl.refresh(from: generation)
        try await accessControl.ensureRulesConfirmed()
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
        try ensureDecisionPermitsRelease(releaseDecision)

        let activeFiller = request.action == .fill ? try (filler ?? XPCCredentialFiller()) : nil
        if let activeFiller {
            let inspection = try await activeFiller.inspect()
            try AgentCredentialFillProcessor(filler: activeFiller, resolver: resolver).validate(
                inspection, candidate: selected, requestedURL: targetURL, field: field)
            try ensureRequestHasNotExpired(request)
            try await accessControl.ensureRulesConfirmed()
            try ensureDecisionPermitsRelease(accessControl.releaseDecision(for: selected.id, field: field))
        }

        var approvalProgress: AgentApprovalProgress?
        let needsApproval = releaseDecision == .requestAuthorization && !grants.contains(selected.id, action: request.action)
        if needsApproval {
            let approval = CredentialReleaseAuthorizationRequest(
                destination: approvalDestination(for: targetURL),
                account: selected.username ?? selected.title,
                field: field,
                credentialTitle: selected.title,
                expirationSeconds: nil,
                fillsFocusedField: request.action == .fill,
                authorizationDeadline: request.expiresAt,
                isPossiblyStale: possiblyStaleCredentialIDs.contains(selected.id)
            )
            try await approvals.authorize(credentialID: selected.id, action: request.action, authorizationDeadline: request.expiresAt,
                onProgress: { progress in
                    approvalProgress = progress
                    onProgress(progress)
                }) { onPromptStarted in
                try await authorize(approval, onPromptStarted)
            }
            grants.approve(selected.id, action: request.action)
        }

        try ensureRequestHasNotExpired(request)
        try await accessControl.ensureRulesConfirmed()
        try ensureDecisionPermitsRelease(accessControl.releaseDecision(for: selected.id, field: field))
        if let activeFiller {
            try await AgentCredentialFillProcessor(filler: activeFiller, resolver: resolver).fill(
                candidate: selected, requestedURL: targetURL, field: field, deadline: request.expiresAt,
                value: {
                    try ensureRequestHasNotExpired(request)
                    try await accessControl.ensureRulesConfirmed()
                    try ensureDecisionPermitsRelease(accessControl.releaseDecision(for: selected.id, field: field))
                    return try resolver.secret(in: generation, targetURL: targetURL,
                        usernameHint: request.usernameHint, candidateID: selected.id, field: field, now: now())
                })
            return AgentBridgeResponse(id: request.id, ok: true, mirror: mirror,
                filledField: field, approvalProgress: approvalProgress)
        }
        let secret = try resolver.secret(
            in: generation,
            targetURL: targetURL,
            usernameHint: request.usernameHint,
            candidateID: request.candidateID,
            field: field
        )
        let codeRecord = field == .totp
            ? generation.items.first(where: { $0.id == selected.id })?.credentials.first(where: {
                if case .totp = $0 { return true }
                return false
            }) : nil
        try CredentialTransfer.publish(secret, requestID: request.id,
            credentialID: selected.id, expiresAfter: 300, codeRecord: codeRecord)
        return AgentBridgeResponse(
            id: request.id,
            ok: true,
            mirror: mirror,
            candidates: [selected],
            copiedField: field,
            approvalProgress: approvalProgress
        )
    }

    private func ensureDecisionPermitsRelease(_ decision: CredentialReleaseDecision) throws {
        switch decision {
        case .release, .requestAuthorization:
            return
        case .needsConfirmation:
            throw AgentBridgeFailure(.rulesNeedConfirmation, AccessRulesConfirmationRequired.message)
        case .block:
            throw AgentBridgeFailure(.policyDenied,
                "Agent access to this credential is blocked in Agent Keyring.")
        }
    }

    private func ensureRequestHasNotExpired(_ request: AgentBridgeRequest) throws {
        guard request.version == 1,
            request.createdAt.timeIntervalSince(now()) <= 5,
            request.expiresAt > now(),
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
