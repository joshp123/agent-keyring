import AgentKeyringProtocol
import Foundation
import OSLog

private let leaseLogger = Logger(subsystem: "com.agentkeyring.app", category: "CredentialLeases")

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func startAgentListener() throws {
        guard agentListener == nil else { return }
        do { try leaseStore.load() }
        catch { leaseLogger.error("Task history needs owner recovery; the socket will report how to reset it.") }
        agentListener = try AgentBridgeServer(bridge: bridge) { [weak self] request, peer, reply in
            guard let self else { return }
            await self.handleLeaseRequest(request, peer: peer, reply: reply)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.loadStatus()
            try? await self.refreshLeasePolicy()
            self.startPendingMacApprovals()
        }
    }

    private func handleLeaseRequest(_ request: Agentkeyring_V1_WireRequest, peer: AgentBridgePeer,
        reply: @escaping @Sendable (Agentkeyring_V1_WireResponse) -> Void) async {
        do {
            guard peer.userID == getuid() else { throw LeaseFailure(.unauthenticated, "The socket peer is not this Mac user.") }
            var response = Agentkeyring_V1_WireResponse()
            response.endOfStream = true
            switch request.request {
            case let .findLogins(query):
                let metadata = metadataIncludingExample(try await store.loadCurrentMetadata())
                leaseLogins = metadata?.candidates ?? []
                await accessControl.refresh(fromMetadata: metadata)
                var result = Agentkeyring_V1_FindLoginsResponse()
                let candidates = metadata?.candidates ?? []
                let terms = query.query.lowercased().split(separator: " ")
                let matching = candidates.filter { login in
                    let text = ([login.title, login.username ?? "", login.id.uuidString] + login.origins).joined(separator: " ").lowercased()
                    return terms.allSatisfy { text.contains($0) }
                }
                result.mirrorRefreshedUnixSeconds = Int64(metadata?.createdAt.timeIntervalSince1970 ?? 0)
                result.logins = matching.map { login in
                    var item = Agentkeyring_V1_Login()
                    item.loginID = login.id.uuidString
                    item.title = login.title
                    item.sites = login.origins
                    item.account = login.username ?? ""
                    item.hasOneTimeCode_p = login.availableFields.contains(.totp)
                    item.rule = switch accessControl.policy(for: login.id) {
                    case .ask: .ask
                    case .allowAutomatically: .automatic
                    case .block: .blocked
                    }
                    return item
                }
                response.logins = result
            case let .requestLease(incoming):
                try await refreshLeasePolicy()
                let login = leaseLogins.first { $0.id == UUID(uuidString: incoming.loginID) }
                response.lease = try leaseStore.request(incoming, login: login,
                    policy: login.map { accessControl.policy(for: $0.id) } ?? .block,
                    requester: CredentialLeaseRequester(AgentRequester.from(peer: peer)), phoneDelaySeconds: approvalRoutingSettings.phoneDelaySeconds)
                startPendingMacApprovals()
            case let .getLease(reference):
                try await refreshLeasePolicy()
                response.lease = try leaseStore.get(reference.leaseID)
            case let .watchLease(reference):
                try await refreshLeasePolicy()
                _ = try leaseStore.get(reference.leaseID)
                var previous: Agentkeyring_V1_Lease?
                for await leases in leaseStore.changes() {
                    guard !Task.isCancelled else { return }
                    guard let lease = leases.first(where: { $0.leaseID == reference.leaseID }) else { continue }
                    guard lease != previous else { continue }
                    previous = lease
                    var update = Agentkeyring_V1_WireResponse()
                    update.lease = lease
                    update.endOfStream = lease.state.isTerminal
                    reply(update)
                    if update.endOfStream { return }
                }
                return
            case let .endLease(reference):
                response.lease = try leaseStore.end(reference.leaseID)
            case let .deliver(operation):
                // Load values before the final policy check. There is no await
                // between checking current policy, returning the values.
                guard let generation = generationIncludingExample(try await store.loadCurrent()) else {
                    throw LeaseFailure(.unavailable, "Import your logins from Apple Passwords first.")
                }
                let currentMetadata = try await refreshLeasePolicy()
                guard currentMetadata?.id == generation.id else {
                    throw LeaseFailure(.unavailable, "The imported logins changed while preparing this operation. Retry the same operation.")
                }
                response.delivery = try leaseStore.deliver(operation) { lease, fields in
                    guard let loginID = UUID(uuidString: lease.loginID),
                        let item = generation.items.first(where: { $0.id == loginID }) else {
                        throw LeaseFailure(.notFound, "The selected login is unavailable.")
                    }
                    let candidate = resolver.candidate(for: item)
                    guard fields.allSatisfy({ candidate.availableFields.contains($0.mirrorField) }) else {
                        throw LeaseFailure(.invalidArgument, "The login does not have every requested field.")
                    }
                    var values = Agentkeyring_V1_CredentialValues()
                    for field in fields {
                        let value = try resolver.value(in: item, field: field.mirrorField)
                        switch field {
                        case .username: values.username = value
                        case .password: values.password = value
                        case .oneTimeCode: values.oneTimeCode = value
                        default: break
                        }
                    }
                    return values
                }
            case .fill, .executeProgram:
                throw LeaseFailure(.invalidArgument, "Fill and ExecuteProgram run in the agent-keyring receiver. Use Deliver on the authority socket.")
            case nil: throw LeaseFailure(.invalidArgument, "Select an authority method.")
            }
            reply(response)
        } catch {
            let failure: LeaseFailure
            if let error = error as? LeaseFailure { failure = error }
            else if error is AccessRulesConfirmationRequired || (error as? AgentBridgeFailure)?.code == .rulesNeedConfirmation {
                failure = LeaseFailure(.permissionDenied, AccessRulesConfirmationRequired.message)
            } else if error is CredentialResolverError { failure = LeaseFailure(.invalidArgument, "The login or requested field is unavailable.") }
            else {
                leaseLogger.error("Authority request failed: \(String(describing: error), privacy: .private)")
                failure = LeaseFailure(.unavailable, "Agent Keyring could not complete this request. Rejoin the same reference; do not request approval again.")
            }
            var response = Agentkeyring_V1_WireResponse()
            response.error.code = failure.code
            response.error.message = failure.message
            response.endOfStream = true
            reply(response)
        }
    }

    @discardableResult
    func refreshLeasePolicy() async throws -> MirrorMetadata? {
        let metadata = metadataIncludingExample(try await store.loadCurrentMetadata())
        leaseLogins = metadata?.candidates ?? []
        await accessControl.refresh(fromMetadata: metadata)
        do { try await accessControl.ensureRulesConfirmed() }
        catch {
            try leaseStore.reconcile(logins: leaseLogins, policies: [:], rulesConfirmed: false)
            throw error
        }
        try leaseStore.reconcile(logins: leaseLogins,
            policies: Dictionary(uniqueKeysWithValues: leaseLogins.map { ($0.id, accessControl.policy(for: $0.id)) }), rulesConfirmed: true)
        return metadata
    }
}

extension Agentkeyring_V1_CredentialField {
    var mirrorField: AgentCredentialField {
        switch self {
        case .username: .username
        case .oneTimeCode: .totp
        default: .password // Validated by CredentialLeaseStore before this mapping.
        }
    }
}
