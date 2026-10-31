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
        if outboxTask == nil {
            outboxTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.flushOutbox()
                    do { try self.expireRequests() } catch { self.report(error) }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        if state.keySet != nil, sessionTask == nil {
            sessionTask = Task { [weak self, lockState] in
                for await _ in lockState.changes {
                    guard let self, !Task.isCancelled else { return }
                    if !lockState.isLocked { self.noteRulesChanged() }
                }
            }
        }
        guard state.keySet != nil, workTask == nil else { return }
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
                let response = try await client.call(command)
                guard state.outbox.first?.bytes == queued.bytes else { continue }
                var next = state
                switch (command.request, response.response) {
                case let (.confirmPairing(confirmation), .enrolment(ack)):
                    guard ack.accepted, let pending = state.pairing else { throw LeaseFailure(.conflict, ack.detail) }
                    next.endpoint = pending.endpoint
                    next.relaySPKI = pending.relaySPKI
                    next.keySet = try confirmation.initialKeySet.serializedData()
                    next.pairing = nil
                    needsPublication = true
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
                        lease.approvedBy = statement.choice == .approve ? (statement.authority == .automaticRule ? .automaticRule : .mac) : .unspecified
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
                case let (.decideEnrolment, .enrolment(ack)):
                    guard ack.accepted else { throw LeaseFailure(.conflict, ack.detail) }
                case let (.publishIndex, .publish(ack)), let (.publishEnrolmentSet, .publish(ack)), let (.publishAutomaticGrant, .publish(ack)), let (.clearDenial_p, .publish(ack)):
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
            if state.approvedEnrolments.values.contains(where: { (try? Agentkeyring_V1_ApprovedEnrolment(serializedBytes: $0).record) == pending.record }) { return }
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
        case .pairing, .lease: break
        case nil: throw LeaseFailure(.invalidArgument, "The relay sent empty work.")
        }
    }

    func expireRequests() throws {
        var next = state
        var changed = false
        for (id, saved) in state.requests {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.state == .pending && saved.decision == nil && lease.pendingUntilUnixSeconds <= Self.now {
                lease.state = .unanswered
            } else if lease.state == .active && lease.notAfterUnixSeconds <= Self.now { lease.state = .expired }
            else { continue }
            lease.endedAtUnixSeconds = Self.now
            next.requests[id]!.lease = try lease.serializedData()
            changed = true
        }
        if changed { try commit(next) }
    }

    func report(_ error: Error) {
        errorMessage = (error as? LeaseFailure)?.message ?? error.localizedDescription
        relayLogger.error("Relay approver: \(self.errorMessage ?? "unavailable", privacy: .public)")
        publish()
    }
}
