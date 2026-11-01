import AgentKeyringProtocol
import Foundation
import OSLog

private let relayLogger = Logger(subsystem: "com.agentkeyring.app", category: "RelayApprover")

extension RelayApprover {
    public func start() {
        do { try load() } catch { report(error); return }
        guard state.endpoint != nil || state.pairing?.confirmation != nil else {
            connectionState = .notPaired; publish(); return
        }
        wakeOutbox()
        do { try leaseStore.setScreenLocked(lockState.isLocked) } catch { report(error) }
        if state.keySet != nil, sessionTask == nil {
            sessionTask = Task { [weak self, lockState] in
                for await _ in lockState.changes {
                    guard let self, !Task.isCancelled else { return }
                    do { try self.leaseStore.setScreenLocked(lockState.isLocked) } catch { self.report(error) }
                    if !lockState.isLocked { self.noteRulesChanged() }
                }
            }
        }
        guard state.endpoint != nil, state.keySet != nil, workTask == nil else { return }
        noteRulesChanged()
        workTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                var connection: RelayConnection?
                do {
                    self.connectionState = .connecting
                    self.publish()
                    var request = Agentkeyring_V1_RelayWireRequest()
                    request.watchWork.approverKeyID = RelayCrypto.keyID(try self.keys().1.publicKey)
                    connection = try await self.transport().open(request)
                    self.connectionState = .connected
                    self.errorMessage = nil
                    self.publish()
                    delay = 1
                    while !Task.isCancelled {
                        let response = try await connection!.next()
                        if case let .work(work) = response.response { try await self.receive(work) }
                        if case let .trustUpdate(update) = response.response { try self.receiveTrustUpdate(update) }
                        if response.endOfStream { throw LeaseFailure(.unavailable, "The relay ended the work stream.") }
                    }
                } catch {
                    if !Task.isCancelled { self.connectionState = .offline; self.report(error) }
                }
                connection?.cancel()
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    public func stop() {
        workTask?.cancel(); workTask = nil
        outboxTask?.cancel(); outboxTask = nil
        sessionTask?.cancel(); sessionTask = nil
        pairConnection?.cancel(); pairConnection = nil
        connectionState = .stopped
        publish()
    }

    public func reconnect() { stop(); start() }

    func wakeOutbox() {
        guard loaded, (!state.outbox.isEmpty || state.hasPendingWithdrawals), outboxTask == nil else { return }
        outboxTask = Task { [weak self] in
            guard let self else { return }
            defer { self.outboxTask = nil }
            var delay = 1
            while !Task.isCancelled && (!self.state.outbox.isEmpty || self.state.hasPendingWithdrawals) {
                await self.flushOutbox()
                do { try await self.collectUpdateReceipts() }
                catch { if !Task.isCancelled { self.report(error) } }
                if self.state.outbox.isEmpty && !self.state.hasPendingWithdrawals { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(30, delay * 2)
            }
        }
    }

    func flushOutbox() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let queued = state.outbox.first, !Task.isCancelled {
            do {
                let command = try Agentkeyring_V1_RelayWireRequest(serializedBytes: queued.bytes)
                if case let .decide(decision) = command.request, rulesAreBeingChecked,
                    try Agentkeyring_V1_DecisionStatement(serializedBytes: decision.statement).choice == .approve { return }
                let client: RelayTransport
                if case .confirmPairing = command.request, let pending = state.pairing {
                    client = RelayTransport(endpoint: pending.endpoint, identity: try keys().0, pin: pending.relaySPKI)
                } else { client = try transport() }
                if case .escalateToPhone = command.request, queued.attempted != true {
                    var next = state
                    next.outbox[0].attempted = true
                    try commit(next)
                }
                let response = try await callRelay(command, using: client)
                guard state.outbox.first?.bytes == queued.bytes else { continue }
                var next = state
                switch (command.request, response.response) {
                case let (.confirmPairing(confirmation), .enrolment(ack)):
                    guard ack.accepted, let pending = state.pairing else { throw LeaseFailure(.conflict, ack.detail) }
                    next.endpoint = pending.endpoint
                    next.relaySPKI = pending.relaySPKI
                    if next.keySet == nil { next.keySet = try confirmation.initialKeySet.serializedData() }
                    next.pairing = nil
                case let (.decide(decision), .decision(ack)):
                    let statement = try Agentkeyring_V1_DecisionStatement(serializedBytes: decision.statement)
                    let id = RelayCrypto.hex(statement.requestDigest)
                    guard var saved = next.requests[id] else { throw LeaseFailure(.notFound, "The queued decision has no local request.") }
                    var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
                    saved.acknowledged = true
                    if ack.accepted {
                        lease.state = statement.choice == .approve ? .active : .denied
                        lease.approvedAtUnixSeconds = statement.choice == .approve ? statement.approvedAtUnixSeconds : 0
                        lease.notAfterUnixSeconds = statement.choice == .approve ? statement.notAfterUnixSeconds : 0
                        lease.approvedBy = statement.authority == .phone ? .iphone
                            : (statement.choice == .approve ? (statement.authority == .automaticRule ? .automaticRule : .mac) : .mac)
                        lease.reply = decision.reply
                        if statement.choice == .deny {
                            lease.endedAtUnixSeconds = Self.now
                            lease.retryNotBeforeUnixSeconds = next.suppressions[lease.recipient.recipientID + "\0" + lease.loginID, default: 0]
                        }
                    } else {
                        // A conflicting or terminal response closes this request.
                        // It cannot authorize a delivery or invite a second touch.
                        let terminal: [Agentkeyring_V1_LeaseState] = [.denied, .expired, .released, .revoked, .cancelled, .unanswered]
                        lease.state = terminal.contains(ack.lease.state) ? ack.lease.state : .cancelled
                        lease.endedAtUnixSeconds = Self.now
                    }
                    let terminal: [Agentkeyring_V1_LeaseState] = [.denied, .expired, .released, .revoked, .cancelled, .unanswered]
                    if terminal.contains(ack.lease.state) {
                        lease.state = ack.lease.state
                        lease.endedAtUnixSeconds = Self.now
                    } else if lease.state == .active && lease.notAfterUnixSeconds <= Self.now {
                        lease.state = .expired
                        lease.endedAtUnixSeconds = Self.now
                    }
                    saved.lease = try lease.serializedData()
                    next.requests[id] = saved
                case let (.publishApproverKeys(keys), .publish(ack)):
                    guard ack.accepted else { throw LeaseFailure(.conflict, ack.detail) }
                    let incoming = try Agentkeyring_V1_ApproverKeySet(serializedBytes: keys.keySet)
                    let current = try Agentkeyring_V1_ApproverKeySet(serializedBytes: currentKeySet().keySet)
                    if incoming.revision >= current.revision { next.keySet = try keys.serializedData() }
                    if queued.id.hasPrefix("approver-pairing:") {
                        next.pendingApprovers?.removeValue(forKey: String(queued.id.dropFirst("approver-pairing:".count)))
                    }
                case let (.revokeLease(reference), .lease(lease)):
                    guard lease.leaseID == reference.leaseID, Self.isTerminal(lease.state) else {
                        throw LeaseFailure(.conflict, "The relay did not end the requested lease.")
                    }
                case let (.publishConfiguration(publication), .publish(ack)):
                    guard ack.accepted else { throw LeaseFailure(.conflict, ack.detail) }
                    next.acknowledgedConfigurationRevision = try Agentkeyring_V1_Configuration(serializedBytes: publication.configuration.configuration).revision
                case let (.publishCopyUpdate, .publish(ack)):
                    guard ack.accepted else { throw LeaseFailure(.conflict, ack.detail) }
                case let (.updateLocalPhoneLease(update), .decision(ack)):
                    guard ack.lease.leaseID == update.lease.leaseID else { throw LeaseFailure(.conflict, "The relay acknowledged another local lease.") }
                case let (.dismissEnrolment, .enrolment(ack)):
                    guard ack.accepted else { throw LeaseFailure(.conflict, ack.detail) }
                case let (.publishUpdateReceipt(signed), .publish(ack)):
                    guard ack.accepted else { throw LeaseFailure(.conflict, ack.detail) }
                    let receipt = try Agentkeyring_V1_UpdateReceipt(serializedBytes: signed.receipt)
                    var target = Agentkeyring_V1_UpdateReceiptQuery()
                    target.kind = receipt.kind
                    target.revision = receipt.revision
                    target.updateSha256 = receipt.updateSha256
                    if next.acknowledgedUpdateReceipts == nil { next.acknowledgedUpdateReceipts = [] }
                    next.acknowledgedUpdateReceipts!.insert(updateID(target))
                    let prefix = "\(receipt.kind.rawValue):"
                    next.acknowledgedUpdateReceipts = next.acknowledgedUpdateReceipts?.filter {
                        !$0.hasPrefix(prefix) || $0 == updateID(target)
                    }
                case let (.escalateToPhone, .publish(ack)), let (.clearDenial_p, .publish(ack)):
                    guard ack.accepted else { throw LeaseFailure(.conflict, ack.detail) }
                default: throw LeaseFailure(.unavailable, "The relay returned an unexpected acknowledgement.")
                }
                next.outbox.removeFirst()
                try commit(next)
                if state.keySet != nil && workTask == nil { start() }
                errorMessage = nil
                publish()
            } catch { if !Task.isCancelled { report(error) }; return }
        }
    }

    func receive(_ work: Agentkeyring_V1_ApproverWork) async throws {
        switch work.item {
        case let .enrolment(pending):
            _ = try validateEnrolment(pending.record)
            let id = RelayCrypto.hex(RelayCrypto.digest("agentkeyring.enrolment.v1", pending.record))
            let record = try Agentkeyring_V1_EnrolmentRecord(serializedBytes: pending.record)
            if state.machines[record.recipientID] != nil { return }
            var next = state
            next.pendingEnrolments[id] = pending.record
            try commit(next)
        case let .request(pending): try await receiveRequest(pending.record)
        case let .cancelledRequestDigestHex(id):
            guard let saved = state.requests[id], saved.decision == nil else { return }
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.state == .pending {
                lease.state = .cancelled
                lease.endedAtUnixSeconds = Self.now
                var next = state
                next.requests[id]!.lease = try lease.serializedData()
                try commit(next)
            }
        case let .pairing(request): try receiveApproverPairing(request)
        case let .lease(lease): try await receiveLeaseReport(lease)
        case let .phoneDecision(answer): try await receivePhoneDecision(answer)
        case let .localLeaseAction(action): try receiveLocalLeaseAction(action)
        case let .trustUpdate(update): try receiveTrustUpdate(update)
        case .copyUpdate: throw LeaseFailure(.permissionDenied, "Login copies must be sent only to their phone.")
        case nil: throw LeaseFailure(.invalidArgument, "The relay sent empty work.")
        }
    }

    func report(_ error: Error) {
        errorMessage = (error as? LeaseFailure)?.message ?? error.localizedDescription
        relayLogger.error("Relay approver: \(self.errorMessage ?? "unavailable", privacy: .public)")
        publish()
    }
}
