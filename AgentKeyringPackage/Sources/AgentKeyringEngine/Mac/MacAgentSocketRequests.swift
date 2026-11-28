#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import OSLog

private let leaseLogger = Logger(subsystem: "com.agentkeyring.app", category: "CredentialLeases")

@available(macOS 26.0, *)
extension MacKeyringEngine {
    public func startAgentListener() throws {
        guard agentListener == nil else { return }
        do { try leaseStore.loadLeaseRecords() }
        catch { leaseLogger.error("The record of agents' leases could not be saved: \(String(describing: error), privacy: .public)") }
        agentListener = try AgentBridgeServer(bridge: bridge) { [weak self] request, peer, reply in
            guard let self else { return }
            await self.handleLeaseRequest(request, peer: peer, reply: reply)
        }
    }

    private func handleLeaseRequest(_ request: Agentkeyring_V2_AgentRequest, peer: AgentBridgePeer,
        reply: @escaping @Sendable (Agentkeyring_V2_AgentResponse) -> Void) async {
        await startupTask?.value
        do {
            guard peer.userID == getuid() else { throw AgentRPCError(.unauthenticated, "The socket peer is not this Mac user.") }
            var response = Agentkeyring_V2_AgentResponse()
            response.endOfStream = true
            switch request.request {
            case let .setup(setup):
                response.setup = try setupResponse(setup)
            case let .findLogins(query):
                response.logins = try await findLoginsResponse(query)
            case let .requestLease(incoming):
                response.lease = try await requestLease(incoming, peer: peer)
            case let .getLease(reference):
                try await refreshLeasePolicy()
                response.lease = try leaseStore.get(reference.leaseID)
            case let .watchLease(reference):
                try await watchLease(reference, reply: reply)
                return
            case let .endLease(reference):
                response.lease = try leaseStore.end(reference.leaseID)
            case let .deliver(operation):
                try await refreshLeasePolicy()
                // A device's Stop reaches this Mac through the approval's grant at the relay.
                if leaseStore.pushedRequests[operation.leaseID] != nil { try await device?.checkNotStopped(lease: operation.leaseID) }
                let lease = try leaseStore.get(operation.leaseID)
                let values = try await values(for: lease, fields: operation.fields)
                // No suspension between this final check of the lease and returning the values.
                response.delivery = try leaseStore.deliver(operation) { _, _ in values }
            case let .pushKey(key):
                _ = try macKeys()
                try device!.setPushCredential(keyID: key.keyID, teamID: key.teamID, privateKey: key.privateKey)
                response.setup = Agentkeyring_V2_SetupResponse()
            case let .complain(complain):
                try keepAgentComplaint(complain)
                response.setup = Agentkeyring_V2_SetupResponse()
            case let .complaints(asked):
                response.complaints = try complaintsResponse(asked)
            case .fill:
                throw AgentRPCError(.invalidArgument, "Fill runs in the agent-keyring command. Use Deliver on the authority socket.")
            case nil: throw AgentRPCError(.invalidArgument, "Select an authority method.")
            }
            reply(response)
        } catch {
            let failure: AgentRPCError
            if let error = error as? AgentRPCError { failure = error }
            else if case MacKeysError.notMade = error { failure = AgentRPCError(.unavailable, MessageCopy.noKeysYet) }
            else {
                leaseLogger.error("Authority request failed: \(String(describing: error), privacy: .public)")
                failure = AgentRPCError(.unavailable, "Agent Keyring could not complete this request. Rejoin the same reference; do not request approval again.")
            }
            var response = Agentkeyring_V2_AgentResponse()
            response.error.code = failure.code
            response.error.message = failure.message
            response.endOfStream = true
            reply(response)
        }
    }

    private func setupResponse(_ setup: Agentkeyring_V2_SetupRequest) throws -> Agentkeyring_V2_SetupResponse {
        var result = Agentkeyring_V2_SetupResponse()
        switch setup.action {
        case .invite:
            _ = try macKeys()
            result.invite = try device!.inviteMachine()
        case .logs:
            result.logLines = device?.logLines(since: setup.sinceUnixSeconds, request: setup.requestID)
                ?? KeyringDiagnosticLog.mac.lines(since: setup.sinceUnixSeconds, request: setup.requestID)
        case .unspecified, .UNRECOGNIZED:
            throw AgentRPCError(.invalidArgument, "Choose a setup action: invite or logs.")
        }
        return result
    }

    /// The logins whose title, account, ID or sites hold every word an agent searched for, with each one's rule.
    private func findLoginsResponse(_ query: Agentkeyring_V2_FindLoginsRequest) async throws -> Agentkeyring_V2_FindLoginsResponse {
        let metadata = try await store.loadCurrentMetadata()
        leaseLogins = metadata?.candidates ?? []
        await accessControl.refresh(fromMetadata: metadata)
        var result = Agentkeyring_V2_FindLoginsResponse()
        let candidates = metadata?.candidates ?? []
        let terms = query.query.lowercased().split(separator: " ")
        let matching = candidates.filter { login in
            let text = ([login.title, login.username ?? "", login.id.uuidString] + login.origins).joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        result.vaultRefreshedUnixSeconds = Int64(metadata?.createdAt.timeIntervalSince1970 ?? 0)
        result.logins = matching.map { login in
            var item = Agentkeyring_V2_Login()
            item.loginID = login.id.uuidString
            item.title = login.title
            item.sites = login.origins
            item.account = login.username ?? ""
            item.hasOneTimeCode_p = login.availableFields.contains(.totp)
            item.rule = accessControl.rule(for: login.id).storedRule
            return item
        }
        return result
    }

    /// An agent's lease request, answered under the login's rule; one waiting for approval is sent to the devices.
    private func requestLease(_ incoming: Agentkeyring_V2_RequestLeaseRequest, peer: AgentBridgePeer) async throws -> Agentkeyring_V2_Lease {
        try await refreshLeasePolicy()
        let login = leaseLogins.first { $0.id == UUID(uuidString: incoming.loginID) }
        if let login, login.isSecretDeleted, localRule(for: login.id) != .blocked {
            throw AgentRPCError(.permissionDenied, MessageCopy.secretDeletedForAgent)
        }
        let requester = AgentRequester.from(peer: peer).named(incoming.agentLabel)
        let lease = try leaseStore.recordLeaseRequest(incoming, login: login,
            rule: login.map { localRule(for: $0.id) } ?? .blocked,
            requester: CredentialLeaseRequester(requester, project: incoming.project))
        KeyringDiagnosticLog.mac.noteDeviceEvent("lease", "requested", ["lease": lease.requestID, "login": incoming.loginID,
            "state": "\(lease.state)", "agent": requester.name])
        if login != nil, lease.state == .waiting, leaseStore.pushedRequests[lease.requestID] == nil {
            device?.ask(for: lease, agent: requester.name, project: incoming.project)
        }
        return lease
    }

    /// Replies with every change to one lease until it ends or the agent goes.
    private func watchLease(_ reference: Agentkeyring_V2_LeaseReference,
                            reply: @escaping @Sendable (Agentkeyring_V2_AgentResponse) -> Void) async throws {
        try await refreshLeasePolicy()
        _ = try leaseStore.get(reference.leaseID)
        var previous: Agentkeyring_V2_Lease?
        for await leases in leaseStore.changes() {
            guard !Task.isCancelled else { return }
            guard let lease = leases.first(where: { $0.requestID == reference.leaseID }) else { continue }
            guard lease != previous else { continue }
            previous = lease
            var update = Agentkeyring_V2_AgentResponse()
            update.lease = lease
            update.endOfStream = lease.state.isTerminal
            reply(update)
            if update.endOfStream { return }
        }
    }

    /// An agent's complaint about this Mac, kept with the Mac's name.
    private func keepAgentComplaint(_ complain: Agentkeyring_V2_ComplainRequest) throws {
        _ = try macKeys()
        var complaint = complain.complaint
        complaint.domain = "agentkeyring.complaint.v2"
        complaint.computer = Host.current().localizedName ?? "Mac"
        try device!.keep(complaint)
    }

    /// The complaints kept since the time asked for.
    private func complaintsResponse(_ asked: Agentkeyring_V2_ComplaintsRequest) throws -> Agentkeyring_V2_Complaints {
        _ = try macKeys()
        return device!.complaints(since: asked.sinceUnixSeconds)
    }

    @discardableResult
    func refreshLeasePolicy() async throws -> MacVaultMetadata? {
        await startupTask?.value
        let metadata = try await store.loadCurrentMetadata()
        leaseLogins = metadata?.candidates ?? []
        await accessControl.refresh(fromMetadata: metadata)
        if !automaticCopiesChecked {
            await noteMissingAutomaticCopies()
        } else {
            try leaseStore.reconcile(logins: leaseLogins, rules: currentRules)
        }
        return metadata
    }
}

extension Agentkeyring_V2_CredentialField {
    var agentCredentialField: AgentCredentialField {
        switch self {
        case .username: .username
        case .oneTimeCode: .totp
        case .password, .unspecified, .UNRECOGNIZED: .password // The lease store validates the field before mapping.
        }
    }
}
#endif
