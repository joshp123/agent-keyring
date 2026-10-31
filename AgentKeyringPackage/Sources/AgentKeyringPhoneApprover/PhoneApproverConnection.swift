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
                                try self.receiveRequest(pending.record)
                            } catch { self.fail(error, stage: "Check pending request") }
                        case let .cancelledRequestDigestHex(id): try self.cancelRequest(id)
                        case let .lease(lease): try self.receiveLease(lease)
                        case .pairing, .enrolment: break // The Mac owns enrolment during release 4 development.
                        case .phoneDecision: break // Sent only to the MacBook (RFC 0006).
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
                case let (.decide(decision), .decision(ack)):
                    let statement = try Agentkeyring_V1_DecisionStatement(serializedBytes: decision.statement)
                    let id = RelayCrypto.hex(statement.requestDigest)
                    guard var saved = next.requests[id] else { throw RelayFailure(.notFound, "The queued answer has no saved request.") }
                    var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
                    guard ack.lease.leaseID == lease.leaseID else { throw RelayFailure(.permissionDenied, "The acknowledgement names a different lease.") }
                    saved.acknowledged = true
                    let terminal: [Agentkeyring_V1_LeaseState] = [.denied, .expired, .released, .revoked, .cancelled, .unanswered]
                    if ack.accepted {
                        lease.state = statement.choice == .approve ? .active : .denied
                        lease.approvedAtUnixSeconds = statement.choice == .approve ? statement.approvedAtUnixSeconds : 0
                        lease.notAfterUnixSeconds = statement.choice == .approve ? statement.notAfterUnixSeconds : 0
                        lease.approvedBy = statement.choice == .approve ? .iphone : .unspecified
                        lease.reply = decision.reply
                        // An exact accepted resend can already be expired, released
                        // or revoked. Acknowledgement never reactivates that lease.
                        if terminal.contains(ack.lease.state) {
                            lease.state = ack.lease.state
                            lease.endedAtUnixSeconds = ack.lease.endedAtUnixSeconds
                        }
                        if statement.choice == .deny {
                            lease.endedAtUnixSeconds = Self.now
                            lease.retryNotBeforeUnixSeconds = statement.approvedAtUnixSeconds + 1800
                        }
                    } else {
                        lease.state = terminal.contains(ack.lease.state) ? ack.lease.state : .cancelled
                        lease.endedAtUnixSeconds = Self.now
                    }
                    saved.lease = try lease.serializedData(); next.requests[id] = saved
                case let (.clearDenial_p(clear), .publish(ack)):
                    guard ack.accepted else { throw RelayFailure(.conflict, "The relay did not clear the denial.") }
                    for (id, saved) in next.requests {
                        var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
                        if lease.recipient.recipientID == clear.recipientID && lease.loginID == clear.loginID && lease.state == .denied {
                            lease.retryNotBeforeUnixSeconds = 0; next.requests[id]!.lease = try lease.serializedData()
                        }
                    }
                case let (.registerPush, .publish(ack)):
                    guard ack.accepted else { throw RelayFailure(.conflict, "The relay did not save the notification delay.") }
                default: throw RelayFailure(.unavailable, "Unexpected answer acknowledgement.")
                }
                next.outbox.removeFirst(); try commit(next)
                lastFailure = nil; publish()
                logger.notice("Outbox command acknowledged")
            } catch { if !Task.isCancelled { fail(error, stage: "Send outbox") }; return }
        }
    }

    public func setAskPhoneAfter(_ delay: Duration) async throws {
        let components = delay.components
        guard components.seconds >= 0, components.seconds < 600, components.attoseconds == 0 else {
            throw RelayFailure(.invalidArgument, "Choose a delay shorter than ten minutes.")
        }
        _ = try transport()
        var command = Agentkeyring_V1_RelayWireRequest()
        command.registerPush.approverKeyID = RelayCrypto.keyID(try keys.signingPublicKey())
        command.registerPush.escalationDelaySeconds = UInt32(components.seconds)
        let response = try await transport().call(command)
        guard case let .publish(ack) = response.response, ack.accepted else {
            throw RelayFailure(.unavailable, "The relay cannot save the notification delay yet.")
        }
        var next = state; next.askPhoneAfter = UInt32(components.seconds); try commit(next)
    }

    func cancelRequest(_ id: String) throws {
        guard let saved = state.requests[id], saved.decision == nil else { return }
        var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
        guard lease.state == .pending else { return }
        lease.state = .cancelled; lease.endedAtUnixSeconds = Self.now
        var next = state; next.requests[id]!.lease = try lease.serializedData(); try commit(next)
    }

    func expireRequests() throws {
        var next = state; var changed = false
        for (id, saved) in state.requests {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.state == .pending && saved.decision == nil && lease.pendingUntilUnixSeconds <= Self.now { lease.state = .unanswered }
            else if lease.state == .active && lease.notAfterUnixSeconds <= Self.now { lease.state = .expired }
            else { continue }
            lease.endedAtUnixSeconds = Self.now; next.requests[id]!.lease = try lease.serializedData(); changed = true
        }
        for (id, bytes) in state.remoteLeases {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: bytes)
            if lease.state == .active && lease.notAfterUnixSeconds <= Self.now {
                lease.state = .expired; lease.endedAtUnixSeconds = Self.now
                next.remoteLeases[id] = try lease.serializedData(); changed = true
            }
        }
        if changed { try commit(next) }
    }
}
