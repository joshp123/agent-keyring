import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation

extension PhoneRelayApprover {
    /// Every foreground connection asks WatchWork for the entire pending backlog.
    public func start() {
        do { try load() } catch { fail(error, stage: "Load approver"); return }
        guard state.keySet != nil, let endpoint = state.endpoint else {
            if state.pairingWanted, let pending = state.pendingPair, pairTask == nil, pairingStartTask == nil {
                pairingStartTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.pairingStartTask = nil }
                    do { try await self.beginPairing(endpoint: pending.endpoint) }
                    catch { if !Task.isCancelled { self.fail(error, stage: "Resume pairing") } }
                }
            }
            return
        }
        if retryTask == nil {
            retryTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.flushOutbox()
                    do { try self.expireRequests() } catch { self.fail(error, stage: "Expire requests") }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
        guard workTask == nil else { return }
        workTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                var stream: RelayConnection?
                do {
                    try await self.refreshAuthority()
                    try Task.checkCancellation()
                    var request = Agentkeyring_V1_RelayWireRequest()
                    request.watchWork.approverKeyID = RelayCrypto.keyID(try self.keys.signingPublicKey())
                    stream = try await self.transport().open(request)
                    self.connection = .connected(service: self.address(endpoint), lastContact: Date())
                    self.connectionFailedAt = nil; self.lastFailure = nil; self.publish(); delay = 1
                    self.logger.notice("Pinned relay connected; fetching pending backlog")
                    while !Task.isCancelled {
                        let response = try await stream!.next()
                        guard case let .work(work) = response.response else { throw RelayFailure(.unavailable, "Unexpected relay work response.") }
                        switch work.item {
                        case let .request(pending):
                            do {
                                try await self.refreshAuthority()
                                try self.receiveRequest(pending)
                            } catch { self.fail(error, stage: "Check pending request") }
                        case .cancelledRequestDigestHex: break // The following Lease carries the actual Mac outcome.
                        case let .lease(lease): try self.receiveLease(lease)
                        case .pairing, .enrolment: break // The Mac owns enrolment during release 4 development.
                        case .phoneDecision, .localLeaseAction: break // Sent only to the MacBook (RFC 0006).
                        case nil: throw RelayFailure(.invalidArgument, "The relay sent empty work.")
                        }
                        if response.endOfStream { throw RelayFailure(.unavailable, "The relay ended the work stream.") }
                    }
                } catch {
                    if !Task.isCancelled {
                        self.connectionFailedAt = self.connectionFailedAt ?? Date()
                        self.connection = .unreachable(service: self.address(endpoint), since: self.connectionFailedAt!)
                        self.fail(error, stage: "Relay connection")
                    }
                }
                stream?.cancel()
                if Task.isCancelled { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }

    public func stop() {
        pairingAttempt = UUID()
        pairingStartTask?.cancel(); pairingStartTask = nil
        workTask?.cancel(); workTask = nil
        retryTask?.cancel(); retryTask = nil
        pairTask?.cancel(); pairTask = nil; pairConnection?.cancel(); pairConnection = nil
    }

    public func reconnect() { stop(); start() }

    func flushOutbox() async {
        guard !flushing else { return }
        flushing = true; defer { flushing = false }
        while let bytes = state.outbox.first, !Task.isCancelled {
            do {
                let command = try Agentkeyring_V1_RelayWireRequest(serializedBytes: bytes)
                let response = try await transport().call(command)
                guard state.outbox.first == bytes else { continue }
                var next = state
                switch (command.request, response.response) {
                case let (.answerFromPhone(decision), .decision(ack)):
                    let statement = try Agentkeyring_V1_PhoneDecision(serializedBytes: decision.decision)
                    let id = RelayCrypto.hex(statement.requestDigest)
                    guard let saved = next.requests[id] else { throw RelayFailure(.notFound, "The queued answer has no saved request.") }
                    let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
                    try validateLease(ack.lease, record: record)
                    next.requests[id]!.acknowledged = true
                    try mergeLease(ack.lease, into: &next)
                    // accepted means the relay retained the answer. Only the Mac's
                    // actual lease update may turn PENDING into ACTIVE or DENIED.
                case let (.clearDenial_p(clear), .publish(ack)):
                    guard ack.accepted else { throw RelayFailure(.conflict, "The relay did not clear the denial.") }
                    for (id, saved) in next.requests {
                        var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
                        if !saved.isLocal && lease.recipient.recipientID == clear.recipientID && lease.loginID == clear.loginID && lease.state == .denied {
                            lease.retryNotBeforeUnixSeconds = 0; next.requests[id]!.lease = try lease.serializedData()
                        }
                    }
                default: throw RelayFailure(.unavailable, "Unexpected answer acknowledgement.")
                }
                next.outbox.removeFirst(); try commit(next)
                lastFailure = nil; publish()
                logger.notice("Outbox command acknowledged")
            } catch { if !Task.isCancelled { fail(error, stage: "Send outbox") }; return }
        }
    }

    func expireRequests() throws {
        let previous = lastDeadlineCheck
        lastDeadlineCheck = Self.now
        let leases = Array(state.remoteLeases.values) + state.requests.values.map(\.lease)
        for bytes in leases {
            let lease = try Agentkeyring_V1_Lease(serializedBytes: bytes)
            let deadline = lease.state == .pending ? lease.pendingUntilUnixSeconds : (lease.state == .active ? lease.notAfterUnixSeconds : 0)
            if deadline > previous && deadline <= lastDeadlineCheck { publish(); return }
        }
    }
}
