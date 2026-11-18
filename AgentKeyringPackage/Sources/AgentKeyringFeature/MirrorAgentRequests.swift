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
        Task { [weak self] in
            guard let self else { return }
            await self.loadStatus()
        }
    }

    private func handleLeaseRequest(_ request: Agentkeyring_V1_WireRequest, peer: AgentBridgePeer,
        reply: @escaping @Sendable (Agentkeyring_V1_WireResponse) -> Void) async {
        do {
            guard peer.userID == getuid() else { throw LeaseFailure(.unauthenticated, "The socket peer is not this Mac user.") }
            var response = Agentkeyring_V1_WireResponse()
            response.endOfStream = true
            switch request.request {
            case let .setup(setup):
                var result = Agentkeyring_V1_SetupResponse()
                switch setup.action {
                case .startRelay:
                    guard !setup.host.isEmpty, let port = UInt16(exactly: setup.port), port > 0 else {
                        throw LeaseFailure(.invalidArgument, "Give a relay host and port.")
                    }
                    _ = try macKeys()
                    result.invite = try await device!.beginSetup(try RelayEndpoint(host: setup.host, port: port),
                        agent: AgentRequester.from(peer: peer).name, reason: setup.reason)
                case .invite:
                    _ = try macKeys()
                    result.invite = try device!.inviteMachine()
                case .relayStatus:
                    _ = try macKeys()
                    result.relayStatus = device!.connection == .connected ? "connected"
                        : device!.isJoined || device!.setup != nil ? "waiting" : "not-started"
                default: throw LeaseFailure(.invalidArgument, "Choose a setup action: start-relay or relay-status.")
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
                    case .ask, .askOnPhone: .ask
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
                    requester: CredentialLeaseRequester(AgentRequester.from(peer: peer), project: incoming.project))
                if let login, accessControl.policy(for: login.id) == .askOnPhone, response.lease.state == .pending {
                    askDevices(for: response.lease, request: incoming, agent: AgentRequester.from(peer: peer).name)
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
            case .fill, .executeProgram:
                throw LeaseFailure(.invalidArgument, "Fill and ExecuteProgram run in the agent-keyring receiver. Use Deliver on the authority socket.")
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

    /// A login only the iPhone or Watch may approve: the request goes to them
    /// through the relay, and the lease follows their answer.
    func askDevices(for lease: Agentkeyring_V1_Lease, request: Agentkeyring_V1_RequestLeaseRequest, agent: String) {
        var ask = Agentkeyring_V2_AskRequest()
        ask.loginID = lease.loginID
        ask.purpose = switch lease.purpose {
        case .program: .program
        case .agentProcess: .agentProcess
        default: .browserSignIn
        }
        if lease.hasProgram {
            ask.program.executable = lease.program.executable
            ask.program.arguments = lease.program.arguments
        }
        ask.reason = lease.reason
        ask.agent = agent
        ask.project = request.project
        ask.task = lease.taskRef
        ask.clientRequestID = lease.leaseID
        let leaseID = lease.leaseID
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let device = self.device else { throw LeaseFailure(.unavailable, "This Mac is not connected to your iPhone or Watch.") }
                switch try await device.askDevices(ask) {
                case let .approved(contents): try self.leaseStore.approveFromDevices(leaseID, contents: contents)
                case let .denied(reply): _ = try self.leaseStore.deny(leaseID, reply: reply, approvedBy: .iphone)
                case .unanswered, .cancelled: try self.leaseStore.expire()
                }
            } catch {
                leaseLogger.error("Asking the iPhone or Watch failed: \(String(describing: error), privacy: .public)")
                _ = try? self.leaseStore.end(leaseID)
            }
        }
    }

    @discardableResult
    func refreshLeasePolicy() async throws -> MirrorMetadata? {
        let metadata = try await store.loadCurrentMetadata()
        leaseLogins = metadata?.candidates ?? []
        await accessControl.refresh(fromMetadata: metadata)
        try leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
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
