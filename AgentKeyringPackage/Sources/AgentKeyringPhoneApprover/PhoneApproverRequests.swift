import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation
import LocalAuthentication

extension PhoneRelayApprover {
    func receiveRequest(_ pending: Agentkeyring_V1_PendingRequest) throws {
        let bytes = pending.record
        let id = RelayCrypto.hex(RelayCrypto.digest("agentkeyring.request.v1", bytes))
        if let previous = state.requests[id] {
            guard previous.record == bytes, previous.sourceMacKeyID == pending.sourceMacKeyID, previous.isLocal == pending.hasLocalLease else { throw RelayFailure(.conflict, "The request changed.") }
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
        let mac = try sourceMac(pending.sourceMacKeyID)
        let login = try indexedLogin(record.loginID)
        let metadata = PhoneRequestLogin(login)
        let machine: Agentkeyring_V1_EnrolledMachine
        if pending.hasLocalLease {
            var local = Agentkeyring_V1_EnrolledMachine()
            local.recipientID = record.recipientID; local.machineLabel = mac.label
            local.clientLabel = record.agentLabel
            machine = local
            try validateLease(pending.localLease, record: record)
            guard pending.localLease.state == .pending, pending.localLease.sites == login.sites else {
                throw RelayFailure(.permissionDenied, "The Mac's local request does not match its signed login index.")
            }
        } else { machine = try self.machine(record.recipientID) }
        var lease = Agentkeyring_V1_Lease()
        lease.leaseID = record.leaseID; lease.loginID = record.loginID; lease.taskRef = record.taskRef
        lease.purpose = record.purpose; lease.reason = record.reason; lease.sites = login.sites
        if record.hasProgram { lease.program = record.program }
        lease.requestedAtUnixSeconds = record.createdUnixSeconds; lease.pendingUntilUnixSeconds = record.pendingUntilUnixSeconds
        lease.recipient.recipientID = machine.recipientID; lease.recipient.machineLabel = machine.machineLabel
        lease.recipient.clientLabel = machine.clientLabel
        if pending.hasLocalLease { lease = pending.localLease; lease.recipient.machineLabel = mac.label }
        lease.state = Self.now < record.pendingUntilUnixSeconds ? .pending : .unanswered
        if lease.state == .unanswered { lease.endedAtUnixSeconds = Self.now }
        var next = state
        next.requests[id] = PhoneSavedRequest(record: bytes, lease: try lease.serializedData(), metadata: metadata,
                                              machine: try machine.serializedData(), sourceMacKeyID: mac.keyID, isLocal: pending.hasLocalLease)
        try commit(next)
        logger.notice("Escalated request checked against signed index and trusted Mac; local=\(pending.hasLocalLease, privacy: .public)")
        if login.rule == .blocked && lease.state == .pending { try queueDecision(id, approve: false, reply: "", context: nil) }
        // Automatic never borrows the phone signing key.
    }

    func pendingScope(_ id: String, approving: Bool) throws -> (Agentkeyring_V1_RequestRecord, Agentkeyring_V1_EnrolledMachine, Agentkeyring_V1_Login) {
        guard let saved = state.requests[id], saved.decision == nil else { throw RelayFailure(.conflict, "This request already has an answer.") }
        let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
        let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
        guard lease.state == .pending, record.pendingUntilUnixSeconds > Self.now else { throw RelayFailure(.conflict, "This request has ended.") }
        let mac = try sourceMac(saved.sourceMacKeyID)
        let machine = try Agentkeyring_V1_EnrolledMachine(serializedBytes: saved.machine)
        if saved.isLocal {
            guard machine.machineLabel == mac.label else { throw RelayFailure(.conflict, "The escalating Mac changed.") }
        } else {
            guard try self.machine(record.recipientID).serializedData() == saved.machine else {
                throw RelayFailure(.permissionDenied, "The receiving machine changed or was revoked.")
            }
        }
        let login = try indexedLogin(record.loginID)
        guard PhoneRequestLogin(login) == saved.metadata else {
            throw RelayFailure(.conflict, "The saved login changed. Ask the agent to request it again.")
        }
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
        logger.notice("Face ID authorized; signing phone answer")
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
        let (record, _, _) = try pendingScope(id, approving: approve)
        var statement = Agentkeyring_V1_PhoneDecision()
        statement.domain = "agentkeyring.phonedecision.v1"
        statement.requestDigest = RelayCrypto.digest("agentkeyring.request.v1", state.requests[id]!.record)
        statement.choice = approve ? .approve : .deny
        statement.decidedUnixSeconds = Self.now
        statement.notAfterUnixSeconds = approve ? statement.decidedUnixSeconds + 1800 : 0
        statement.leaseID = record.leaseID
        statement.replySha256 = RelayCrypto.hash(Data(reply.utf8))
        var decision = Agentkeyring_V1_SignedPhoneDecision()
        decision.phoneKeyID = RelayCrypto.keyID(try keys.signingPublicKey()); decision.reply = reply
        decision.decision = try statement.serializedData()
        if approve || !reply.isEmpty {
            guard let context else { throw RelayFailure(.permissionDenied, "Face ID is required.") }
            decision.signature = try keys.sign(decision.decision, context: context)
        }
        var command = Agentkeyring_V1_RelayWireRequest(); command.answerFromPhone = decision
        var next = state
        next.requests[id]!.decision = try decision.serializedData()
        next.outbox.append(try command.serializedData())
        try commit(next)
        logger.notice("Phone answer committed to durable outbox; approve=\(approve, privacy: .public)")
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
                                                              account: saved.metadata.account),
                                 agent: RequestingAgent(name: record.agentLabel, machine: machine.machineLabel, address: record.tailscaleAddress),
                                 access: purpose, agentReason: record.reason, askedAt: Date(timeIntervalSince1970: Double(record.createdUnixSeconds)),
                                 state: try screenState(saved), events: [AccessRequestEvent(Date(timeIntervalSince1970: Double(lease.requestedAtUnixSeconds)), "Request received")],
                                 answerIsQueued: saved.decision != nil && !saved.acknowledged && lease.state == .pending)
        }
        let localLeaseIDs = Set(try state.requests.values.map { try Agentkeyring_V1_RequestRecord(serializedBytes: $0.record).leaseID })
        let remote = try state.remoteLeases.values.compactMap { bytes -> AccessRequest? in
            let lease = try Agentkeyring_V1_Lease(serializedBytes: bytes)
            guard !localLeaseIDs.contains(lease.leaseID), lease.state != .pending,
                  let login = try? indexedLogin(lease.loginID),
                  let machine = try? machine(lease.recipient.recipientID) else { return nil }
            let access: RequestedAccess = lease.purpose == .program ? .program(([lease.program.executable] + lease.program.arguments).joined(separator: " ")) : (lease.purpose == .agentProcess ? .agentProcess : .signIn)
            return AccessRequest(id: "lease:" + lease.leaseID,
                                 login: RequestedLogin(site: login.sites.first.flatMap { URL(string: $0)?.host } ?? login.title, account: login.account),
                                 agent: RequestingAgent(name: machine.clientLabel, machine: machine.machineLabel, address: ""), access: access,
                                 agentReason: lease.reason, askedAt: Date(timeIntervalSince1970: Double(lease.requestedAtUnixSeconds)),
                                 state: screenState(lease, verifiedReply: nil), events: [])
        }
        return (local + remote).sorted { $0.askedAt > $1.askedAt }
    }

    func screenState(_ saved: PhoneSavedRequest) throws -> AccessRequestState {
        let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
        if let bytes = saved.decision, lease.state == .pending {
            let signed = try Agentkeyring_V1_SignedPhoneDecision(serializedBytes: bytes)
            let statement = try Agentkeyring_V1_PhoneDecision(serializedBytes: signed.decision)
            let choice: AnswerChoice = statement.choice == .approve ? .approve : .deny
            return saved.acknowledged ? .waitingForMac(choice, reply: signed.reply.isEmpty ? nil : signed.reply) : .sendingAnswer(choice)
        }
        return screenState(lease, verifiedReply: saved.decision.flatMap { try? Agentkeyring_V1_SignedPhoneDecision(serializedBytes: $0).reply })
    }

    func screenState(_ lease: Agentkeyring_V1_Lease, verifiedReply: String?) -> AccessRequestState {
        switch lease.state {
        case .pending:
            return lease.pendingUntilUnixSeconds > Self.now ? .waitingForYou(until: Date(timeIntervalSince1970: Double(lease.pendingUntilUnixSeconds))) : .unanswered
        case .active:
            if lease.notAfterUnixSeconds <= Self.now { return .expired(at: Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds))) }
            return .approved(by: lease.approvedBy == .iphone ? .iPhone : (lease.approvedBy == .automaticRule ? .automaticRule : .mac), until: Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds)))
        case .denied: return .denied(by: lease.approvedBy == .iphone ? .iPhone : .mac, reply: (lease.reply.isEmpty ? verifiedReply : lease.reply).flatMap { $0.isEmpty ? nil : $0 },
                                    askAgainAfter: lease.retryNotBeforeUnixSeconds > Self.now ? Date(timeIntervalSince1970: Double(lease.retryNotBeforeUnixSeconds)) : nil)
        case .released: return .released(at: Date(timeIntervalSince1970: Double(lease.endedAtUnixSeconds)))
        case .revoked: return .ended(at: Date(timeIntervalSince1970: Double(lease.endedAtUnixSeconds)))
        case .expired: return .expired(at: Date(timeIntervalSince1970: Double(lease.endedAtUnixSeconds)))
        case .cancelled: return .cancelled
        default: return .unanswered
        }
    }
}
