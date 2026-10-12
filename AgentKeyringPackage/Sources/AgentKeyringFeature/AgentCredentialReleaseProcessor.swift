import Foundation

@MainActor
public struct AgentCredentialReleaseProcessor {
    private let bridge: AgentBridgeDirectory
    private let accessControl: CredentialAccessController
    private let resolver: CredentialResolver

    public init(
        bridge: AgentBridgeDirectory,
        accessControl: CredentialAccessController,
        resolver: CredentialResolver = CredentialResolver()
    ) {
        self.bridge = bridge
        self.accessControl = accessControl
        self.resolver = resolver
    }

    public func release(
        request: AgentBridgeRequest,
        generation: MirrorGeneration,
        authorize: (CredentialReleaseAuthorizationRequest) async throws -> Void,
        copyNative: (String, TimeInterval) -> Void
    ) async throws -> AgentBridgeResponse {
        guard request.action == .copy || request.action == .acquire else {
            throw AgentBridgeFailure(.invalidRequest, "A credential release action is required.")
        }
        try ensureRequestIsLive(request)
        await accessControl.refresh(from: generation)
        let mirror = AgentMirrorSummary(
            importedAt: generation.createdAt,
            ageSeconds: max(0, Int(Date().timeIntervalSince(generation.createdAt))),
            credentialCount: generation.items.count
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

        if releaseDecision == .requestAuthorization {
            let approval = CredentialReleaseAuthorizationRequest(
                destination: approvalDestination(for: targetURL),
                account: selected.username ?? selected.title,
                field: field,
                credentialTitle: selected.title,
                expirationSeconds: request.action == .copy ? min(120, max(5, request.expirationSeconds)) : nil,
                authorizationDeadline: request.createdAt.addingTimeInterval(120)
            )
            try await authorize(approval)
        }

        try ensureRequestIsLive(request)
        let secret = try resolver.secret(
            in: generation,
            targetURL: targetURL,
            usernameHint: request.usernameHint,
            candidateID: request.candidateID,
            field: field
        )
        let expiration = min(120, max(5, request.expirationSeconds))
        if request.action == .acquire {
            if field == .totp,
                let item = generation.items.first(where: { $0.id == selected.id }),
                let record = item.credentials.first(where: {
                    if case .totp = $0 { return true }
                    return false
                }) {
                try CredentialTransfer.publishCode(record, requestID: request.id)
            } else {
                try CredentialTransfer.publish(secret, requestID: request.id)
            }
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

    private func ensureRequestIsLive(_ request: AgentBridgeRequest) throws {
        guard request.version == 1,
            request.createdAt.timeIntervalSinceNow <= 5,
            request.createdAt.addingTimeInterval(120) > Date(),
            bridge.requestMatches(request),
            bridge.callerIsAlive(pid: request.callerPID)
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
