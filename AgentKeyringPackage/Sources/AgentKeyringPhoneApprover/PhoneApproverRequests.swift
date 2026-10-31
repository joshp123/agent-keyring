import AgentKeyringApprovalUI
import AgentKeyringPhoneVault
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation
import LocalAuthentication

extension PhoneRelayApprover {
    func receiveRequest(_ bytes: Data) throws {
        let id = RelayCrypto.hex(RelayCrypto.digest("agentkeyring.request.v1", bytes))
        if let previous = state.requests[id] {
            guard previous.record == bytes else { throw RelayFailure(.conflict, "The request changed.") }
            return
        }
        let record = try Agentkeyring_V1_RequestRecord(serializedBytes: bytes)
        guard !record.leaseID.isEmpty, !record.requestID.isEmpty, !record.loginID.isEmpty,
              !record.taskRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [.browserSignIn, .program, .agentProcess].contains(record.purpose),
              record.hasProgram == (record.purpose == .program),
              record.createdUnixSeconds > 0, record.createdUnixSeconds <= Self.now + 60,
              record.pendingUntilUnixSeconds > record.createdUnixSeconds,
              record.pendingUntilUnixSeconds - record.createdUnixSeconds <= 600 else {
            throw RelayFailure(.invalidArgument, "The request has invalid scope or deadline.")
        }
        if record.hasProgram {
            guard record.program.executable.hasPrefix("/"), !record.program.executable.utf8.contains(0),
                  !record.program.arguments.contains(where: { $0.utf8.contains(0) }) else {
                throw RelayFailure(.invalidArgument, "The requested program is invalid.")
            }
        }
        for saved in state.requests.values {
            let previous = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
            guard previous.leaseID != record.leaseID,
                  previous.recipientID != record.recipientID || previous.requestID != record.requestID else {
                throw RelayFailure(.conflict, "The relay reused a request or lease with different scope.")
            }
        }
        let machine = try machine(record.recipientID)
        guard let login = try vault.logins().first(where: { $0.loginID == record.loginID && $0.match != .needsReview }) else {
            throw RelayFailure(.notFound, "The phone has no matched login for this request.")
        }
        var lease = Agentkeyring_V1_Lease()
        lease.leaseID = record.leaseID; lease.loginID = record.loginID; lease.taskRef = record.taskRef
        lease.purpose = record.purpose; lease.reason = record.reason; lease.sites = login.metadata.sites
        if record.hasProgram { lease.program = record.program }
        lease.requestedAtUnixSeconds = record.createdUnixSeconds; lease.pendingUntilUnixSeconds = record.pendingUntilUnixSeconds
        lease.recipient.recipientID = machine.recipientID; lease.recipient.machineLabel = machine.machineLabel
        lease.recipient.clientLabel = machine.clientLabel
        lease.state = Self.now < record.pendingUntilUnixSeconds ? .pending : .unanswered
        if lease.state == .unanswered { lease.endedAtUnixSeconds = Self.now }
        var next = state
        next.requests[id] = PhoneSavedRequest(record: bytes, lease: try lease.serializedData(), metadata: login.metadata,
                                              machine: try machine.serializedData())
        try commit(next)
        logger.notice("Pending request checked against phone vault and signed machine roster")
        if login.rule == .blocked && lease.state == .pending { try queueDecision(id, approve: false, reply: "", context: nil) }
        // Automatic never borrows the human key. R4.6 delegates it to the relay.
    }

    func pendingScope(_ id: String, approving: Bool) throws -> (Agentkeyring_V1_RequestRecord, Agentkeyring_V1_EnrolledMachine, PhoneIndexedLogin) {
        guard let saved = state.requests[id], saved.decision == nil else { throw RelayFailure(.conflict, "This request already has an answer.") }
        let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
        let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
        guard lease.state == .pending, record.pendingUntilUnixSeconds > Self.now else { throw RelayFailure(.conflict, "This request has ended.") }
        let machine = try machine(record.recipientID)
        guard try machine.serializedData() == saved.machine else { throw RelayFailure(.permissionDenied, "The receiving machine changed or was revoked.") }
        guard let login = try vault.logins().first(where: { $0.loginID == record.loginID && $0.match != .needsReview }),
              login.metadata == saved.metadata else { throw RelayFailure(.conflict, "The saved login changed. Ask the agent to request it again.") }
        guard !approving || login.rule == .ask else { throw RelayFailure(.permissionDenied, "Only a current Ask login can be approved on this iPhone.") }
        return (record, machine, login)
    }

    public func approve(_ id: String) async throws -> AccessRequestState {
        try load()
        if state.requests[id]?.decision != nil { await flushOutbox(); return try requestState(id) }
        guard !authorizing else { throw RelayFailure(.conflict, "An approval is already in progress.") }
        authorizing = true; defer { authorizing = false }
        try await refreshAuthority()
        let (record, machine, _) = try pendingScope(id, approving: true)
        let context = LAContext(); defer { context.invalidate() }
        logger.notice("Requesting Face ID for explicit approval")
        try await keys.authorize(context, reason: "Allow this login for the task on \(machine.machineLabel), up to 30 minutes")
        try Task.checkCancellation()
        logger.notice("Explicit approval authorized; opening and sealing login")
        // After Face ID there are no network calls before durable enqueue.
        guard record == (try pendingScope(id, approving: true)).0 else { throw RelayFailure(.conflict, "The request changed.") }
        try queueDecision(id, approve: true, reply: "", context: context)
        await flushOutbox()
        return try requestState(id)
    }

    public func deny(_ id: String, reply: String?) async throws -> AccessRequestState {
        try load()
        if state.requests[id]?.decision != nil { await flushOutbox(); return try requestState(id) }
        let reply = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !authorizing else { throw RelayFailure(.conflict, "An approval is already in progress.") }
        authorizing = true; defer { authorizing = false }
        try await refreshAuthority()
        _ = try pendingScope(id, approving: false)
        if reply.isEmpty { try queueDecision(id, approve: false, reply: "", context: nil) }
        else {
            let context = LAContext(); defer { context.invalidate() }
            try await keys.authorize(context, reason: "Send your reply when denying this Agent Keyring request")
            try Task.checkCancellation()
            try queueDecision(id, approve: false, reply: reply, context: context)
        }
        await flushOutbox()
        return try requestState(id)
    }

    func queueDecision(_ id: String, approve: Bool, reply: String, context: LAContext?) throws {
        let (record, machine, _) = try pendingScope(id, approving: approve)
        var statement = Agentkeyring_V1_DecisionStatement()
        statement.domain = "agentkeyring.decision.v1"
        statement.requestDigest = RelayCrypto.digest("agentkeyring.request.v1", state.requests[id]!.record)
        statement.choice = approve ? .approve : .deny
        statement.approvedAtUnixSeconds = Self.now
        statement.notAfterUnixSeconds = approve ? Self.now + 1800 : 0
        statement.recipientID = machine.recipientID; statement.receiverKeyID = machine.receiverKeyID; statement.leaseID = record.leaseID
        statement.replySha256 = RelayCrypto.hash(Data(reply.utf8))
        statement.authority = !approve && reply.isEmpty ? .approverConnection : .human
        var decision = Agentkeyring_V1_SignedDecision()
        decision.approverKeyID = RelayCrypto.keyID(try keys.signingPublicKey()); decision.reply = reply
        if approve {
            guard let context else { throw RelayFailure(.permissionDenied, "Face ID is required.") }
            let item = try vault.openAskLogin(loginID: record.loginID) { try keys.sharedSecret(with: $0, context: context) }
            logger.notice("Opened Face ID protected vault item")
            let contents = try RelayLoginBundle.contents(item: item, loginID: record.loginID, leaseID: record.leaseID,
                                                         approvedAt: statement.approvedAtUnixSeconds, notAfter: statement.notAfterUnixSeconds)
            decision.bundle = try RelayCrypto.seal(contents, receiverKey: machine.receiverPublicKey, requestDigest: statement.requestDigest)
            statement.bundleCiphertextSha256 = RelayCrypto.hash(decision.bundle.ciphertext)
            logger.notice("Sealed login and timed codes to enrolled receiver")
        }
        decision.statement = try statement.serializedData()
        if statement.authority == .human {
            guard let context else { throw RelayFailure(.permissionDenied, "Face ID is required.") }
            decision.signature = try keys.sign(decision.statement, context: context)
            logger.notice("Signed decision with the explicit action authentication context")
        }
        var command = Agentkeyring_V1_RelayWireRequest(); command.decide = decision
        var next = state
        next.requests[id]!.decision = try decision.serializedData()
        next.outbox.append(try command.serializedData())
        try commit(next)
        logger.notice("Decision sealed and committed to outbox; approve=\(approve, privacy: .public)")
    }

    public func clearDenial(_ id: String) async throws -> AccessRequestState {
        try load()
        guard let saved = state.requests[id] else { throw RelayFailure(.notFound, "No such request.") }
        let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
        var command = Agentkeyring_V1_RelayWireRequest()
        command.clearDenial_p.recipientID = record.recipientID; command.clearDenial_p.loginID = record.loginID
        var next = state; next.outbox.append(try command.serializedData()); try commit(next)
        await flushOutbox(); return try requestState(id)
    }

    public func requestState(_ id: String) throws -> AccessRequestState {
        guard let saved = state.requests[id] else { throw RelayFailure(.notFound, "No such request.") }
        return try screenState(saved)
    }

    public func requests() throws -> [AccessRequest] {
        let local = try state.requests.map { id, saved in
            let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
            let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            let machine = try Agentkeyring_V1_EnrolledMachine(serializedBytes: saved.machine)
            let purpose: RequestedAccess = switch record.purpose {
            case .program: .program(([record.program.executable] + record.program.arguments).joined(separator: " "))
            case .agentProcess: .agentProcess
            default: .signIn
            }
            return AccessRequest(id: id, login: RequestedLogin(site: saved.metadata.sites.first.flatMap { URL(string: $0)?.host } ?? saved.metadata.title,
                                                              account: saved.metadata.account ?? ""),
                                 agent: RequestingAgent(name: record.agentLabel, machine: machine.machineLabel, address: record.tailscaleAddress),
                                 access: purpose, agentReason: record.reason, askedAt: Date(timeIntervalSince1970: Double(record.createdUnixSeconds)),
                                 state: try screenState(saved), events: [AccessRequestEvent(Date(timeIntervalSince1970: Double(lease.requestedAtUnixSeconds)), "Request received")])
        }
        let localLeaseIDs = Set(try state.requests.values.map { try Agentkeyring_V1_RequestRecord(serializedBytes: $0.record).leaseID })
        let remote = try state.remoteLeases.values.compactMap { bytes -> AccessRequest? in
            let lease = try Agentkeyring_V1_Lease(serializedBytes: bytes)
            guard !localLeaseIDs.contains(lease.leaseID), lease.state != .pending,
                  let login = try vault.logins().first(where: { $0.loginID == lease.loginID && $0.match != .needsReview }),
                  let machine = try? machine(lease.recipient.recipientID) else { return nil }
            let access: RequestedAccess = lease.purpose == .program ? .program(([lease.program.executable] + lease.program.arguments).joined(separator: " ")) : (lease.purpose == .agentProcess ? .agentProcess : .signIn)
            return AccessRequest(id: "lease:" + lease.leaseID,
                                 login: RequestedLogin(site: login.metadata.sites.first.flatMap { URL(string: $0)?.host } ?? login.metadata.title, account: login.metadata.account ?? ""),
                                 agent: RequestingAgent(name: machine.clientLabel, machine: machine.machineLabel, address: ""), access: access,
                                 agentReason: lease.reason, askedAt: Date(timeIntervalSince1970: Double(lease.requestedAtUnixSeconds)),
                                 state: screenState(lease, verifiedReply: nil), events: [])
        }
        return (local + remote).sorted { $0.askedAt > $1.askedAt }
    }

    func screenState(_ saved: PhoneSavedRequest) throws -> AccessRequestState {
        let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
        if let bytes = saved.decision, !saved.acknowledged {
            let signed = try Agentkeyring_V1_SignedDecision(serializedBytes: bytes)
            let statement = try Agentkeyring_V1_DecisionStatement(serializedBytes: signed.statement)
            return .sendingAnswer(statement.choice == .approve ? .approve : .deny)
        }
        return screenState(lease, verifiedReply: saved.decision.flatMap { try? Agentkeyring_V1_SignedDecision(serializedBytes: $0).reply })
    }

    func screenState(_ lease: Agentkeyring_V1_Lease, verifiedReply: String?) -> AccessRequestState {
        switch lease.state {
        case .pending: return .waitingForYou(until: Date(timeIntervalSince1970: Double(lease.pendingUntilUnixSeconds)))
        case .active: return .approved(by: lease.approvedBy == .iphone ? .iPhone : (lease.approvedBy == .automaticRule ? .automaticRule : .mac), until: Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds)))
        case .denied: return .denied(by: .iPhone, reply: verifiedReply.flatMap { $0.isEmpty ? nil : $0 },
                                    askAgainAfter: lease.retryNotBeforeUnixSeconds > Self.now ? Date(timeIntervalSince1970: Double(lease.retryNotBeforeUnixSeconds)) : nil)
        case .released: return .released(at: Date(timeIntervalSince1970: Double(lease.endedAtUnixSeconds)))
        case .revoked: return .ended(at: Date(timeIntervalSince1970: Double(lease.endedAtUnixSeconds)))
        case .expired: return .expired(at: Date(timeIntervalSince1970: Double(lease.endedAtUnixSeconds)))
        case .cancelled: return .cancelled
        default: return .unanswered
        }
    }
}
