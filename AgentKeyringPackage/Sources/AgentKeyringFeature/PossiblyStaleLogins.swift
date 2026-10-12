import Foundation

@MainActor
final class PossiblyStaleLogins {
    private let settings: UserDefaults
    init(settings: UserDefaults) { self.settings = settings }

    var credentialIDs: Set<UUID> {
        Set((settings.stringArray(forKey: "possiblyStaleCredentialIDs") ?? []).compactMap(UUID.init(uuidString:)))
    }

    func mark(_ candidates: [CredentialCandidate]) {
        settings.set(credentialIDs.union(candidates.map(\.id)).map(\.uuidString), forKey: "possiblyStaleCredentialIDs")
    }

    func clear() { settings.removeObject(forKey: "possiblyStaleCredentialIDs") }

    func annotate(_ candidate: CredentialCandidate) -> CredentialCandidate {
        CredentialCandidate(id: candidate.id, title: candidate.title, username: candidate.username,
            origins: candidate.origins, availableFields: candidate.availableFields,
            possiblyStale: credentialIDs.contains(candidate.id))
    }
}

extension MirrorAppModel {
    func processSync(request: AgentBridgeRequest, metadata: MirrorMetadata) async throws -> AgentBridgeResponse {
        guard let targetURL = request.targetURL else {
            throw AgentBridgeFailure(.invalidRequest, "The sync request needs a site.")
        }
        let candidates = try resolver.candidates(in: metadata, targetURL: targetURL)
        guard !candidates.isEmpty else { throw CredentialResolverError.notFound }
        staleLogins.mark(candidates)
        guard let syncReminders else {
            throw AgentBridgeFailure(.internalError, "Agent Keyring's sync notifications are unavailable.")
        }
        try await syncReminders.notify(importedAt: metadata.createdAt, immediately: true)
        return AgentBridgeResponse(id: request.id, ok: true)
    }
}
