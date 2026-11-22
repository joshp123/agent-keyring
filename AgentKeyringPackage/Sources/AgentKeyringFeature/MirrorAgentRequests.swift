import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation
import OSLog

private let leaseLogger = Logger(subsystem: "com.agentkeyring.app", category: "CredentialLeases")

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func startAgentListener() throws {
        guard agentListener == nil else { return }
        do { try leaseStore.load() }
        catch { leaseLogger.error("The record of agents' leases could not be saved: \(String(describing: error), privacy: .public)") }
        agentListener = try AgentBridgeServer(bridge: bridge) { [weak self] request, peer, reply in
            guard let self else { return }
            await self.handleLeaseRequest(request, peer: peer, reply: reply)
        }
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.loadStatus()
        }
    }

    private func handleLeaseRequest(_ request: Agentkeyring_V1_WireRequest, peer: AgentBridgePeer,
        reply: @escaping @Sendable (Agentkeyring_V1_WireResponse) -> Void) async {
        await startupTask?.value
        do {
            guard peer.userID == getuid() else { throw LeaseFailure(.unauthenticated, "The socket peer is not this Mac user.") }
            var response = Agentkeyring_V1_WireResponse()
            response.endOfStream = true
            switch request.request {
            case let .setup(setup):
                var result = Agentkeyring_V1_SetupResponse()
                switch setup.action {
                case .startRelay:
                    throw LeaseFailure(.invalidArgument, "There is no relay any more. Run 'agent-keyring invite' on this Mac and enrol the other computer with its link.")
                case .invite:
                    _ = try macKeys()
                    result.invite = try device!.inviteMachine()
                case .relayStatus:
                    _ = try macKeys()
                    result.relayStatus = device!.door.address != nil ? "connected" : "waiting"
                case .logs:
                    result.logLines = device?.logLines(since: setup.sinceUnixSeconds, request: setup.requestID)
                        ?? DiagnosticLog.recent(since: setup.sinceUnixSeconds, request: setup.requestID)
                default: throw LeaseFailure(.invalidArgument, "Choose a setup action: invite, relay-status or logs.")
                }
                response.setup = result
            case let .findLogins(query):
                let metadata = try await store.loadCurrentMetadata()
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
                let requester = AgentRequester.from(peer: peer).named(incoming.agentLabel)
                response.lease = try leaseStore.request(incoming, login: login,
                    policy: login.map { localPolicy(for: $0.id) } ?? .block,
                    requester: CredentialLeaseRequester(requester, project: incoming.project))
                DiagnosticLog.record("lease", "requested", ["lease": response.lease.leaseID, "login": incoming.loginID,
                    "state": "\(response.lease.state)", "agent": requester.name])
                if login != nil, response.lease.state == .pending, leaseStore.pushedRequests[response.lease.leaseID] == nil {
                    device?.ask(for: response.lease, agent: requester.name, project: incoming.project)
                }
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
                try await refreshLeasePolicy()
                let lease = try leaseStore.get(operation.leaseID)
                let values = try await values(for: lease, fields: operation.fields)
                // No suspension between this final check of the lease and returning the values.
                response.delivery = try leaseStore.deliver(operation) { _, _ in values }
            case let .pushKey(key):
                _ = try macKeys()
                try device!.setPushCredential(keyID: key.keyID, teamID: key.teamID, privateKey: key.privateKey)
                response.setup = Agentkeyring_V1_SetupResponse()
            case let .complain(complain):
                _ = try macKeys()
                var complaint = Agentkeyring_V2_Complaint()
                complaint.domain = "agentkeyring.complaint.v2"
                complaint.atUnixSeconds = complain.complaint.atUnixSeconds
                complaint.computer = Host.current().localizedName ?? "Mac"
                complaint.version = complain.complaint.version
                complaint.command = complain.complaint.command
                complaint.thread = complain.complaint.thread
                complaint.summary = complain.complaint.summary
                complaint.detail = complain.complaint.detail
                try device!.keep(complaint)
                response.setup = Agentkeyring_V1_SetupResponse()
            case let .complaints(asked):
                _ = try macKeys()
                var result = Agentkeyring_V1_ComplaintsResponse()
                result.complaints = device!.complaints(since: asked.sinceUnixSeconds).complaints.map { kept in
                    var complaint = Agentkeyring_V1_Complaint()
                    complaint.atUnixSeconds = kept.atUnixSeconds
                    complaint.computer = kept.computer
                    complaint.version = kept.version
                    complaint.command = kept.command
                    complaint.thread = kept.thread
                    complaint.summary = kept.summary
                    complaint.detail = kept.detail
                    return complaint
                }
                response.complaints = result
            case .fill:
                throw LeaseFailure(.invalidArgument, "Fill runs in the agent-keyring command. Use Deliver on the authority socket.")
            case nil: throw LeaseFailure(.invalidArgument, "Select an authority method.")
            }
            reply(response)
        } catch {
            let failure: LeaseFailure
            if let error = error as? LeaseFailure { failure = error }
            else {
                leaseLogger.error("Authority request failed: \(String(describing: error), privacy: .public)")
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
        await startupTask?.value
        let metadata = try await store.loadCurrentMetadata()
        leaseLogins = metadata?.candidates ?? []
        await accessControl.refresh(fromMetadata: metadata)
        if !automaticCopiesChecked {
            await noteMissingAutomaticCopies()
        } else {
            try leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        }
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
