import Foundation
import OSLog

private let agentBridgeLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "AgentBridge"
)

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func receiveAgentRequest(_ url: URL) {
        guard url.scheme == "agentkeyring",
            url.host == "agent",
            let idText = url.pathComponents.last,
            let id = UUID(uuidString: idText)
        else {
            agentBridgeLogger.error("Ignored malformed agent request URL")
            return
        }

        guard handledAgentRequests.insert(id).inserted else {
            agentBridgeLogger.notice("Ignored duplicate agent request")
            return
        }

        agentBridgeLogger.info("Received agent request")
        Task { await handleAgentRequest(id: id) }
    }

    func handleAgentRequest(id: UUID) async {
        defer { bridge.removeRequest(id: id) }
        let response: AgentBridgeResponse
        do {
            let request = try bridge.readRequest(id: id)
            guard request.version == 1, request.id == id else {
                throw AgentBridgeFailure(.invalidRequest, "The agent request is invalid.")
            }
            let receivedAt = Date()
            guard request.createdAt.timeIntervalSince(receivedAt) <= 5, request.expiresAt > receivedAt else {
                throw AgentBridgeFailure(
                    .requestExpired, "The agent request expired before it was handled.")
            }
            switch request.action {
            case .status, .resolve:
                response = try await processDiscovery(request: request,
                    metadata: store.loadCurrentMetadata())
            case .acquire:
                guard let generation = generationIncludingExample(try await store.loadCurrent()) else {
                    throw AgentBridgeFailure(.mirrorUnavailable, "No encrypted mirror is available yet.")
                }
                response = try await processRelease(request: request, generation: generation)
            }
        } catch let failure as AgentBridgeFailure {
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: failure.code,
                message: failure.message
            )
        } catch let error as CredentialResolverError {
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: bridgeCode(for: error),
                message: error.localizedDescription
            )
        } catch let error as CredentialReleaseAuthorizationError {
            let code: AgentBridgeErrorCode =
                switch error {
                case .unavailable, .systemFailure: .authorizationUnavailable
                case .denied: .authorizationDenied
                case .interrupted: .authorizationInterrupted
                case .notVerified: .authorizationNotVerified
                case .expired: .requestExpired
                }
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: code,
                message: error.localizedDescription
            )
        } catch {
            agentBridgeLogger.error(
                "Agent request failed: \(String(describing: error), privacy: .private)"
            )
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: .internalError,
                message: "Agent Keyring could not handle the agent request."
            )
        }

        do {
            try bridge.write(response)
            agentBridgeLogger.info(
                "Completed agent request; success: \(response.ok, privacy: .public)")
        } catch {
            CredentialTransfer.clear(requestID: id)
            agentBridgeLogger.error("Could not write the safe agent response")
        }
    }

    private func processDiscovery(
        request: AgentBridgeRequest,
        metadata: MirrorMetadata?
    ) async throws -> AgentBridgeResponse {
        if request.action == .status, metadata == nil {
            return AgentBridgeResponse(id: request.id, ok: true,
                message: "No mirror has been imported yet.")
        }
        guard let metadata = metadataIncludingExample(metadata) else {
            throw AgentBridgeFailure(.mirrorUnavailable, "No encrypted mirror is available yet.")
        }
        await accessControl.refresh(fromMetadata: metadata)
        let mirror = AgentMirrorSummary(importedAt: metadata.createdAt,
            ageSeconds: max(0, Int(Date().timeIntervalSince(metadata.createdAt))),
            credentialCount: metadata.safeStatus.credentialItemCount)
        if request.action == .status {
            return AgentBridgeResponse(id: request.id, ok: true, mirror: mirror)
        }
        guard let targetURL = request.targetURL else {
            throw AgentBridgeFailure(.invalidRequest, "The resolve request needs a target URL.")
        }
        let candidates = try resolver.candidates(in: metadata, targetURL: targetURL,
            usernameHint: request.usernameHint)
        guard !candidates.isEmpty else {
            return AgentBridgeResponse(id: request.id, ok: false, error: .notFound,
                message: CredentialResolverError.notFound.localizedDescription,
                mirror: mirror, candidates: [])
        }
        return AgentBridgeResponse(id: request.id, ok: true, mirror: mirror, candidates: candidates)
    }

    private func processRelease(
        request: AgentBridgeRequest,
        generation: MirrorGeneration
    ) async throws -> AgentBridgeResponse {
        try await AgentCredentialReleaseProcessor(
            bridge: bridge, accessControl: accessControl, resolver: resolver, grants: grants, approvals: approvals
        ).release(
            request: request,
            generation: generation,
            onProgress: { progress in
                do { try self.bridge.write(progress, id: request.id) }
                catch { agentBridgeLogger.error("Could not write approval status") }
            },
            authorize: { approval, onPromptStarted in
                try await self.authorizeCredentialRelease(approval, agentRequest: request, onPromptStarted: onPromptStarted)
            }
        )
    }

    private func bridgeCode(for error: CredentialResolverError) -> AgentBridgeErrorCode {
        switch error {
        case .invalidURL: .invalidURL
        case .insecureOrigin: .insecureOrigin
        case .notFound: .notFound
        case .ambiguous: .ambiguous
        case .fieldUnavailable: .fieldUnavailable
        case .invalidTOTP: .invalidTOTP
        }
    }
}
