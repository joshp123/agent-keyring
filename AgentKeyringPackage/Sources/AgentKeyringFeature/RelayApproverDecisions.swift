import AgentKeyringProtocol
import Foundation
import LocalAuthentication

extension RelayApprover {
    func receiveRequest(_ bytes: Data) async throws {
        let digest = RelayCrypto.digest("agentkeyring.request.v1", bytes)
        let id = RelayCrypto.hex(digest)
        if let saved = state.requests[id] {
            guard saved.record == bytes else { throw LeaseFailure(.conflict, "The request bytes changed.") }
            if saved.decision == nil { try await decideByRule(id) }
            return
        }
        let record = try Agentkeyring_V1_RequestRecord(serializedBytes: bytes)
        guard !record.leaseID.isEmpty, !record.requestID.isEmpty, UUID(uuidString: record.loginID) != nil,
            !record.taskRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !record.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            [.browserSignIn, .program, .agentProcess].contains(record.purpose),
            record.hasProgram == (record.purpose == .program),
            record.createdUnixSeconds > 0, record.createdUnixSeconds <= Self.now + 60,
            record.pendingUntilUnixSeconds > record.createdUnixSeconds,
            record.pendingUntilUnixSeconds - record.createdUnixSeconds <= 600 else {
            throw LeaseFailure(.invalidArgument, "The remote request has an invalid scope or pending deadline.")
        }
        if record.hasProgram {
            guard record.program.executable.hasPrefix("/"), !record.program.executable.utf8.contains(0),
                !record.program.arguments.contains(where: { $0.utf8.contains(0) }) else {
                throw LeaseFailure(.invalidArgument, "The remote program needs an absolute executable and valid arguments.")
            }
        }
        guard let machineBytes = state.machines[record.recipientID] else {
            throw LeaseFailure(.permissionDenied, "This Mac has not enrolled the receiving machine.")
        }
        let vault = try await credentialSource()
        // Work and owner actions can arrive while the mirror is opening.
        if state.requests[id] != nil { return }
        guard state.machines[record.recipientID] == machineBytes else { throw LeaseFailure(.permissionDenied, "The receiving machine changed.") }
        for saved in state.requests.values {
            let old = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
            guard old.leaseID != record.leaseID,
                old.recipientID != record.recipientID || old.requestID != record.requestID else {
                throw LeaseFailure(.conflict, "The relay reused a lease or request ID with different contents.")
            }
        }
        guard let item = vault.generation.items.first(where: { $0.id == UUID(uuidString: record.loginID) }) else {
            throw LeaseFailure(.notFound, "The remote request names a login that is not in this Mac's mirror.")
        }
        let machine = try Agentkeyring_V1_EnrolledMachine(serializedBytes: machineBytes)
        let candidate = CredentialResolver().candidate(for: item)
        var lease = Agentkeyring_V1_Lease()
        lease.leaseID = record.leaseID
        lease.loginID = record.loginID
        lease.taskRef = record.taskRef
        lease.purpose = record.purpose
        lease.reason = record.reason
        lease.requestedAtUnixSeconds = Self.now
        lease.pendingUntilUnixSeconds = min(record.pendingUntilUnixSeconds, Self.now + 600)
        lease.recipient.recipientID = machine.recipientID
        lease.recipient.machineLabel = machine.machineLabel
        lease.recipient.clientLabel = machine.clientLabel
        lease.sites = item.origins
        if record.hasProgram { lease.program = record.program }
        lease.state = lease.pendingUntilUnixSeconds > Self.now ? .pending : .unanswered
        if lease.state == .unanswered { lease.endedAtUnixSeconds = Self.now }
        var next = state
        next.requests[id] = RelaySavedRequest(record: bytes, lease: try lease.serializedData(), title: item.title,
            account: candidate.username ?? "", machine: machineBytes)
        try commit(next)
        try await decideByRule(id)
    }

    func decideByRule(_ id: String) async throws {
        guard let saved = state.requests[id], saved.decision == nil,
            try Agentkeyring_V1_Lease(serializedBytes: saved.lease).state == .pending else { return }
        let vault = try await credentialSource()
        let scope = try pendingScope(id, vault: vault)
        if vault.policies[scope.item.id, default: .ask] == .block
            || state.suppressions[suppressionKey(scope.record), default: 0] > Self.now {
            try queueDecision(id, approve: false, reply: "", automatic: false, context: nil, vault: vault, suppress: false)
        } else if canApproveAutomatically(scope.record, vault: vault), !lockState.isLocked {
            try queueDecision(id, approve: true, reply: "", automatic: true, context: nil, vault: vault, suppress: false)
        }
    }

    public func approve(_ id: String, context: LAContext = LAContext()) async throws {
        try load()
        if state.requests[id]?.decision != nil { await flushOutbox(); return }
        try claimAuthorization("request:" + id)
        defer { authorizationID = nil }
        let before = try pendingScope(id, vault: await credentialSource())
        guard before.policy != .block else { throw LeaseFailure(.permissionDenied, "This login is blocked.") }
        let signer = try keys().1
        try await signer.authorize(context: context, reason: "Allow \(before.item.title) for this task on \(before.machine.machineLabel), up to 30 minutes")
        let vault = try await credentialSource()
        try Task.checkCancellation()
        try queueDecision(id, approve: true, reply: "", automatic: false, context: context, vault: vault, suppress: false)
        await flushOutbox()
    }

    public func deny(_ id: String, reply: String = "", context: LAContext = LAContext()) async throws {
        try load()
        if state.requests[id]?.decision != nil { await flushOutbox(); return }
        let hasReply = !reply.isEmpty
        if hasReply {
            try claimAuthorization("reply:" + id)
            defer { authorizationID = nil }
            _ = try pendingScope(id, vault: await credentialSource())
            try await keys().1.authorize(context: context, reason: "Send your reply when denying this Agent Keyring request")
        }
        let vault = try await credentialSource()
        try Task.checkCancellation()
        try queueDecision(id, approve: false, reply: reply, automatic: false, context: hasReply ? context : nil,
            vault: vault, suppress: true)
        await flushOutbox()
    }

    public func clearDenial(loginID: String, recipientID: String) async throws {
        try load()
        var next = state
        next.suppressions.removeValue(forKey: recipientID + "\0" + loginID)
        var command = Agentkeyring_V1_RelayWireRequest()
        command.clearDenial_p.recipientID = recipientID
        command.clearDenial_p.loginID = loginID
        try enqueue(command, id: "clear-denial:" + UUID().uuidString, into: &next)
        try commit(next)
        start()
        await flushOutbox()
    }

    func pendingScope(_ id: String, vault: RelayApproverVault) throws -> (record: Agentkeyring_V1_RequestRecord, item: MirrorItem,
        machine: Agentkeyring_V1_EnrolledMachine, policy: CredentialAccessPolicy) {
        guard let saved = state.requests[id] else { throw LeaseFailure(.notFound, "No such remote request.") }
        let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
        guard saved.decision == nil, lease.state == .pending, lease.pendingUntilUnixSeconds > Self.now else {
            throw LeaseFailure(.conflict, "This request has already ended or has an answer waiting for delivery.")
        }
        let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
        guard let machineBytes = state.machines[record.recipientID], machineBytes == saved.machine else {
            throw LeaseFailure(.permissionDenied, "This machine is no longer enrolled with the same receiving key.")
        }
        let machine = try Agentkeyring_V1_EnrolledMachine(serializedBytes: machineBytes)
        guard machine.receiverKeyID == RelayCrypto.keyID(machine.receiverPublicKey),
            let item = vault.generation.items.first(where: { $0.id == UUID(uuidString: record.loginID) }) else {
            throw LeaseFailure(.notFound, "The login or its enrolled receiving key is no longer available.")
        }
        return (record, item, machine, vault.policies[item.id, default: .ask])
    }

    func canApproveAutomatically(_ record: Agentkeyring_V1_RequestRecord, vault: RelayApproverVault) -> Bool {
        guard state.publicationDigest == publicationDigest(vault, machines: state.machines),
            let loginID = UUID(uuidString: record.loginID), vault.policies[loginID, default: .ask] == .allowAutomatically,
            let bytes = state.automaticGrant,
            let signed = try? Agentkeyring_V1_SignedAutomaticGrant(serializedBytes: bytes),
            let grant = try? Agentkeyring_V1_AutomaticGrant(serializedBytes: signed.grant),
            let signer = try? keys().1,
            grant.automaticSigningPublicKey == signer.automaticPublicKey,
            grant.loginIds.contains(record.loginID), grant.recipientIds.contains(record.recipientID),
            let machineBytes = state.machines[record.recipientID],
            let machine = try? Agentkeyring_V1_EnrolledMachine(serializedBytes: machineBytes), machine.automaticAllowed else { return false }
        return true
    }

    func queueDecision(_ id: String, approve: Bool, reply: String, automatic: Bool, context: LAContext?,
        vault: RelayApproverVault, suppress: Bool) throws {
        if state.requests[id]?.decision != nil { return }
        let scope = try pendingScope(id, vault: vault)
        if approve {
            guard scope.policy != .block, !lockState.isLocked else { throw LeaseFailure(.permissionDenied, "This login is blocked or the Mac is locked.") }
            if automatic {
                guard canApproveAutomatically(scope.record, vault: vault) else { throw LeaseFailure(.permissionDenied, "The current rules do not grant Automatic access to this machine.") }
            }
        }
        let signer = try keys().1
        var statement = Agentkeyring_V1_DecisionStatement()
        statement.domain = "agentkeyring.decision.v1"
        statement.requestDigest = RelayCrypto.digest("agentkeyring.request.v1", state.requests[id]!.record)
        statement.choice = approve ? .approve : .deny
        statement.approvedAtUnixSeconds = Self.now
        statement.notAfterUnixSeconds = approve ? statement.approvedAtUnixSeconds + 1800 : 0
        statement.recipientID = scope.record.recipientID
        statement.receiverKeyID = scope.machine.receiverKeyID
        statement.leaseID = scope.record.leaseID
        statement.replySha256 = RelayCrypto.hash(Data(reply.utf8))
        statement.authority = automatic ? .automaticRule : ((!approve && reply.isEmpty) ? .approverConnection : .human)
        if automatic {
            let signed = try Agentkeyring_V1_SignedAutomaticGrant(serializedBytes: state.automaticGrant!)
            statement.automaticGrantRevision = try Agentkeyring_V1_AutomaticGrant(serializedBytes: signed.grant).revision
        }
        var decision = Agentkeyring_V1_SignedDecision()
        decision.approverKeyID = RelayCrypto.keyID(automatic ? signer.automaticPublicKey : signer.publicKey)
        decision.reply = reply
        if approve {
            let contents = try RelayCrypto.bundle(item: scope.item, leaseID: scope.record.leaseID,
                approvedAt: statement.approvedAtUnixSeconds, notAfter: statement.notAfterUnixSeconds)
            decision.bundle = try RelayCrypto.seal(contents, receiverKey: scope.machine.receiverPublicKey, requestDigest: statement.requestDigest)
            statement.bundleCiphertextSha256 = RelayCrypto.hash(decision.bundle.ciphertext)
        }
        decision.statement = try statement.serializedData()
        if statement.authority != .approverConnection {
            decision.signature = try signer.sign(decision.statement, context: context, automatic: automatic)
        }
        var next = state
        next.requests[id]!.decision = try decision.serializedData()
        if suppress { next.suppressions[suppressionKey(scope.record)] = Self.now + 1800 }
        var command = Agentkeyring_V1_RelayWireRequest()
        command.decide = decision
        try enqueue(command, id: "decision:" + id, into: &next)
        try commit(next)
    }

    func suppressionKey(_ record: Agentkeyring_V1_RequestRecord) -> String { record.recipientID + "\0" + record.loginID }
}
