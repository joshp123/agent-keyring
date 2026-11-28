// Written by AI on 2026.11.21 by model claude opus 5.5, from the relay's
// requests (since deleted); through answer boxes and grants, with the door cut, on 2026.11.24.
//
// This Mac as the computer that asks, for its own agents' requests and for
// practice requests: it writes and signs each request naming an answer box at
// the relay, pushes it to the iPhone and Apple Watch through Apple, and reads
// their answers from the box (keyring.proto, "Boxes"). For an
// agent's request the lease store is the record (CredentialLeaseStore): the
// first answer wins there against this Mac's own panel, and its hold after a
// denial applies. An approval has a grant at the relay, which a device's Stop
// marks, and which is read before every use. Every outcome goes to the devices
// as a silent push.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation

@MainActor
extension MacSyncCoordinator {
    /// One request this Mac pushed.
    struct OutgoingApprovalRequest {
        /// The Request bytes and this Mac's signature over them.
        let signed: Agentkeyring_V2_Signed
        let request: Agentkeyring_V2_Request
        /// An agent's lease; nil for a practice request.
        let leaseID: String?
        var pushed: Int64 = 0
        var answeredBy = ""
        var endedBy = ""
        /// A practice request's own state, and his words if he denied it.
        var practice = Agentkeyring_V2_LeaseState.waiting
        var reply = ""
        /// The last state the devices were told of.
        var lastAnnouncedState = Agentkeyring_V2_LeaseState.waiting
        /// Its grant is at the relay.
        var grantPut = false
    }

    /// Whether an agent's request on this Mac can also go to the iPhone and Apple Watch now, and if not, why.
    public var devicesUnreachable: String? {
        let devices = members?.devices.filter { $0.kind == .iphone || $0.kind == .watch } ?? []
        guard let first = devices.first else { return MessageCopy.noIPhoneOrWatch }
        guard push != nil else { return MessageCopy.noPushKey }
        guard devices.contains(where: { registration(for: $0.keyID) != nil }) else {
            return MessageCopy.noPushAddress(first.label)
        }
        return nil
    }

    static func newID() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    /// Cuts a claim to `limit` bytes on a character boundary, so the push still fits Apple's 4 KB.
    static func fitted(_ text: String, _ limit: Int) -> String {
        var text = text
        while text.utf8.count > limit { text.removeLast() }
        return text
    }

    private func signed(_ request: Agentkeyring_V2_Request) throws -> Agentkeyring_V2_Signed {
        try CredentialSealing.signedDocument(request.serializedData(), by: keys.machineID) { try keys.tls.signWithTLSKey($0) }
    }

    /// A request whose answers go to a new answer box at the relay this Mac uses.
    private func newRequest(id: String, answerBy: Int64) throws -> Agentkeyring_V2_Request {
        var request = Agentkeyring_V2_Request()
        request.domain = "agentkeyring.request.v2"
        request.requestID = id
        request.machineID = keys.machineID
        request.askedUnixSeconds = Int64(Date().timeIntervalSince1970)
        request.answerByUnixSeconds = answerBy
        request.answerBoxID = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        request.answerBoxKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        if environment.relay.url != RelayBoxProtocol.defaultURL { request.answerBoxURL = environment.relay.url }
        return request
    }

    // MARK: An agent's request

    /// An agent on this Mac asked and its lease waits: the request also goes to
    /// the iPhone and Apple Watch. This Mac never waits for them: if they cannot
    /// be reached, the request is shown here alone, and the log says why.
    public func ask(for lease: Agentkeyring_V2_Lease, agent: String, project: String) {
        if let why = devicesUnreachable {
            KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "not-asked", ["lease": lease.requestID, "reason": why])
            return
        }
        do {
            var request = try newRequest(id: Self.newID(), answerBy: lease.answerByUnixSeconds)
            request.loginID = lease.loginID
            request.reason = Self.fitted(lease.authorityContext.reason, 400)
            request.agent = Self.fitted(agent, 100)
            request.project = Self.fitted(project, 100)
            request.task = Self.fitted(lease.authorityContext.taskRef, 100)
            let document = try signed(request)
            try leaseStore.notePushed(lease.requestID, request: document.serializedData())
            asks[request.requestID] = OutgoingApprovalRequest(signed: document, request: request, leaseID: lease.requestID)
            KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "asked", ["lease": lease.requestID, "request": request.requestID, "login": lease.loginID])
            enqueuePushes(request.requestID, waiting: true)
            readAnswerBox(request.requestID)
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "not-asked", ["lease": lease.requestID, "reason": "\(error)"])
        }
    }

    /// After a restart: every lease whose request went to the devices is followed again, so their answers are still taken.
    func resumeAsks() {
        for (leaseID, bytes) in leaseStore.pushedRequests {
            guard let document = try? Agentkeyring_V2_Signed(serializedBytes: bytes),
                let request = try? CredentialSealing.parseRequest(document.payload) else { continue }
            let state = (try? leaseStore.get(leaseID))?.state ?? .unspecified
            let lastAnnouncedState = state == .waiting || state == .approved ? state : .unspecified
            asks[request.requestID] = OutgoingApprovalRequest(signed: document, request: request, leaseID: leaseID, lastAnnouncedState: lastAnnouncedState,
                                          grantPut: leaseStore.grantsPut.contains(leaseID))
            if state == .waiting { readAnswerBox(request.requestID) }
        }
        leasesChanged()
    }

    /// The lease store is the record: each change there is told to the devices once, as a silent push.
    func followLeases() {
        guard leaseFollowing == nil else { return }
        let changes = leaseStore.changes()
        leaseFollowing = Task { [weak self] in
            for await _ in changes { self?.leasesChanged() }
        }
    }

    func leasesChanged() {
        for (id, ask) in asks {
            guard let leaseID = ask.leaseID, let lease = lease(id) else { continue }
            let effective = CredentialRequestLifecycle.effectiveState(of: lease, now: .now)
            // Approved, here or on a device: its grant goes to the relay, so any device can stop it.
            if effective == .approved, !ask.grantPut, askTasks[id]?.grant == nil, !ask.request.answerBoxID.isEmpty { putGrant(id) }
            if effective != .waiting, CredentialRequestLifecycle.canTransition(from: ask.lastAnnouncedState, to: effective) {
                asks[id]?.lastAnnouncedState = effective
                enqueuePushes(id, waiting: false)
            }
            if effective.isTerminal {
                askTasks[id]?.answer?.cancel()
                askTasks[id]?.answer = nil
                if askTasks[id]?.isEmpty == true { askTasks.removeValue(forKey: id) }
                try? leaseStore.forgetPushed(leaseID)
            }
        }
        pruneOldTerminalAsks()
        askSignal.fire()
    }

    private func removeAsk(_ id: String) {
        asks.removeValue(forKey: id)
        askTasks.removeValue(forKey: id)?.cancelAll()
    }

    private func pruneOldTerminalAsks() {
        let cutoff = Int64(Date().timeIntervalSince1970) - 86_400
        for (id, ask) in asks {
            if let leaseID = ask.leaseID {
                guard let local = try? leaseStore.get(leaseID) else {
                    if ask.request.answerByUnixSeconds < cutoff {
                        removeAsk(id)
                    }
                    continue
                }
                guard local.state != .waiting, local.state != .approved else { continue }
                let mapped = lease(id).map { CredentialRequestLifecycle.effectiveState(of: $0, now: .now) } ?? .ended
                guard ask.lastAnnouncedState == mapped else { continue }
                let endedAt = local.endedAtUnixSeconds > 0 ? local.endedAtUnixSeconds : ask.request.answerByUnixSeconds
                if endedAt < cutoff {
                    removeAsk(id)
                }
            } else if ask.practice != .waiting, ask.lastAnnouncedState == ask.practice, ask.request.answerByUnixSeconds < cutoff {
                removeAsk(id)
            }
        }
    }

    /// The request as the devices see it, from the lease store for an agent's, or its own record for a practice request.
    func lease(_ id: String) -> Agentkeyring_V2_Lease? {
        guard let ask = asks[id] else { return nil }
        var lease: Agentkeyring_V2_Lease
        if let leaseID = ask.leaseID {
            guard var local = try? leaseStore.get(leaseID) else { return nil }
            if local.authorityContext.decidingDeviceKind == .mac { local.answeredBy = keys.label }
            if local.state == .ended { local.endedBy = ask.endedBy.isEmpty ? keys.label : ask.endedBy }
            local.clearAuthorityContext()
            lease = local
        } else {
            lease = Agentkeyring_V2_Lease()
            lease.loginID = ask.request.loginID
            lease.answerByUnixSeconds = ask.request.answerByUnixSeconds
            lease.state = ask.practice
            lease.reply = ask.reply
        }
        lease.requestID = id
        lease.pushedUnixSeconds = ask.pushed
        if !ask.answeredBy.isEmpty { lease.answeredBy = ask.answeredBy }
        return lease
    }

    // MARK: Practice

    /// A practice request on another device of Josh's: it arrives there like a
    /// real one, and this ends when that device answers or ten minutes pass.
    /// `progress` hears each step on the way (sent, with Apple).
    public func sendPracticeRequest(on deviceKeyID: String, progress: @MainActor (Agentkeyring_V2_Lease) -> Void) async throws -> Agentkeyring_V2_Lease {
        let id = try makePractice(for: deviceKeyID, id: Self.newID())
        var last = Agentkeyring_V2_Lease()
        while true {
            guard let lease = lease(id) else { throw AgentRPCError(.notFound, MessageCopy.somethingWentWrong) }
            if lease != last { progress(lease); last = lease }
            if lease.state != .waiting { return lease }
            await askSignal.wait(until: .now + .seconds(30))
            try Task.checkCancellation()
        }
    }

    /// Makes and pushes a practice request for one device, or returns the one
    /// already waiting for it: the same id again rejoins, and there is at most one per device.
    func makePractice(for target: String, id: String) throws -> String {
        guard let device = members?.devices.first(where: { $0.keyID == target }), target != keys.deviceKeyID else {
            throw AgentRPCError(.notFound, MessageCopy.noIPhoneOrWatch)
        }
        if let existing = asks[id], existing.request.forDeviceKeyID == target { return id }
        if let waiting = asks.first(where: { $0.value.request.forDeviceKeyID == target && $0.value.practice == .waiting && $0.value.leaseID == nil })?.key {
            return waiting
        }
        if push == nil { throw AgentRPCError(.unavailable, MessageCopy.noPushKey) }
        guard registration(for: target) != nil else { throw AgentRPCError(.unavailable, MessageCopy.noPushAddress(device.label)) }
        var request = try newRequest(id: id, answerBy: Int64(Date().timeIntervalSince1970) + 600)
        request.reason = "You asked me to download October’s invoice."
        request.agent = "Agent Keyring"
        request.project = "Practice"
        request.forDeviceKeyID = target
        asks[id] = OutgoingApprovalRequest(signed: try signed(request), request: request, leaseID: nil)
        KeyringDiagnosticLog.mac.noteDeviceEvent("practice", "sent", ["request": id, "device": device.label])
        enqueuePushes(id, waiting: true)
        readAnswerBox(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            self?.endPractice(id, .unanswered, by: nil, reply: "")
        }
        return id
    }

    private func endPractice(_ id: String, _ state: Agentkeyring_V2_LeaseState, by device: Agentkeyring_V2_Device?, reply: String) {
        guard let current = asks[id]?.practice, CredentialRequestLifecycle.canTransition(from: current, to: state) else { return }
        asks[id]?.practice = state
        asks[id]?.reply = reply
        asks[id]?.answeredBy = device?.label ?? ""
        asks[id]?.lastAnnouncedState = state
        askTasks[id]?.answer?.cancel()
        askTasks[id]?.answer = nil
        if askTasks[id]?.isEmpty == true { askTasks.removeValue(forKey: id) }
        KeyringDiagnosticLog.mac.noteDeviceEvent("practice", "answered", ["request": id, "state": "\(state)"])
        enqueuePushes(id, waiting: false)
        askSignal.fire()
    }

    // MARK: Pushes

    /// One request's pushes go one at a time, each with the state as it is
    /// then: a request ended at once must not leave its alert arriving after the push that clears it.
    func enqueuePushes(_ id: String, waiting: Bool) {
        var entry = askTasks[id] ?? AskTasks()
        let previous = entry.push
        entry.push = Task { [weak self] in
            await previous?.value
            await self?.sendPushes(id, waiting: waiting)
        }
        askTasks[id] = entry
    }

    private func sendPushes(_ id: String, waiting: Bool) async {
        guard let push, let ask = asks[id], let members else { return }
        let outcome = waiting ? nil : lease(id)
        let targets = members.devices.filter { device in
            device.keyID != keys.deviceKeyID && (ask.request.forDeviceKeyID.isEmpty || device.keyID == ask.request.forDeviceKeyID)
        }
        for device in targets {
            guard let registration = registration(for: device.keyID),
                let noticeKey = try? P256.KeyAgreement.PublicKey(x963Representation: registration.noticePublicKey) else { continue }
            var envelope = Agentkeyring_V2_SignedRequestEnvelope()
            envelope.request = ask.signed.payload
            envelope.requestSignature = ask.signed.signature
            if !ask.request.forDeviceKeyID.isEmpty {
                envelope.login = Self.practiceLogin()
            }
            if let outcome { envelope.outcome = outcome }
            guard let notice = try? CredentialSealing.sealNotice(envelope, to: noticeKey, deviceKeyID: device.keyID) else { continue }
            // A Mac shows a waiting request in its own panel: its push is silent, so a Mac not running shows no banner.
            // iPhone and Apple Watch use alert transport for both waiting and passive outcome pushes so outcomes
            // collapse the waiting alert reliably at priority 10 instead of being throttled as priority-5 background pushes.
            let waitingVisible = waiting && device.kind != .mac
            let alertTransport = PushPayload.usesAlertTransport(waiting: waiting, for: device.kind)
            let payload = PushPayload.pushRequest(id: id, notice: notice, waiting: waitingVisible, for: device.kind)
            guard payload.count <= PushPayload.largest else {
                KeyringDiagnosticLog.mac.noteDeviceEvent("push", "too-large", ["request": id, "device": device.label, "bytes": "\(payload.count)"])
                continue
            }
            let expiration = waiting ? ask.request.answerByUnixSeconds : Int64(Date().timeIntervalSince1970) + 3600
            do {
                try await push.sendPush(payload, to: registration, collapseID: id, expiration: expiration, visible: alertTransport)
                if waiting, asks[id]?.pushed == 0 {
                    asks[id]?.pushed = Int64(Date().timeIntervalSince1970)
                    askSignal.fire()
                }
                KeyringDiagnosticLog.mac.noteDeviceEvent("push", "accepted", ["request": id, "device": device.label, "visible": "\(waitingVisible)"])
            } catch let failure as ApplePushError where failure.invalidToken {
                if self.registration(for: device.keyID)?.apnsToken == registration.apnsToken {
                    saved.pushRegistrations.removeValue(forKey: device.keyID)
                    persist()
                    cloudSync.pushCloudSoon()
                }
                KeyringDiagnosticLog.mac.noteDeviceEvent("push", "address-gone", ["device": device.label, "reason": failure.reason])
            } catch {
                KeyringDiagnosticLog.mac.noteDeviceEvent("push", "not-sent", ["request": id, "device": device.label, "reason": "\(error)"])
            }
        }
    }

    private static func practiceLogin() -> Agentkeyring_V2_Login {
        var practice = Agentkeyring_V2_Login()
        practice.title = "example.com"
        practice.sites = ["example.com"]
        practice.account = "you@example.com"
        return practice
    }

    /// The practice panel here was answered, and the request it showed came from another device: the
    /// answer goes in that request's box, signed with this Mac's reply key (nothing is delivered).
    func answerDevicePractice(approved: Bool, reply: String) {
        guard let envelope = devicePractice, let request = try? CredentialSealing.parseRequest(envelope.request), let relay = RelayBoxClient(for: request) else { return }
        devicePractice = nil
        var answer = Agentkeyring_V2_Answer()
        answer.domain = "agentkeyring.answer.v2"
        answer.requestSha256 = CredentialSealing.sha256(envelope.request)
        answer.choice = approved ? .approve : .deny
        answer.decidedUnixSeconds = Int64(Date().timeIntervalSince1970)
        if approved { answer.notAfterUnixSeconds = answer.decidedUnixSeconds + 60 } else { answer.reply = reply }
        guard let signed = try? CredentialSealing.signedDocument(answer.serializedData(), by: keys.replyKeyID, sign: keys.signReply) else { return }
        var upload = Agentkeyring_V2_AnswerUpload()
        upload.answer = signed
        Task {
            do { try await relay.putRelayBox(upload.serializedData(), box: request.answerBoxID, key: request.answerBoxKey) } catch {
                KeyringDiagnosticLog.mac.noteDeviceEvent("practice", "answer-not-sent", ["request": request.requestID, "reason": "\(error)"])
            }
        }
    }

    // MARK: Answer boxes and grants

    /// Reads a waiting request's answer box at `RelayBoxProtocol.every`'s pace until a device answers or a little after its
    /// time runs out (an answer given in time still counts), then takes the answer, and only then deletes it. Started again after a restart for every request still waiting.
    func readAnswerBox(_ id: String) {
        guard let request = asks[id]?.request, !request.answerBoxID.isEmpty else { return }
        let relay = environment.relay
        askTasks[id]?.answer?.cancel()
        var entry = askTasks[id] ?? AskTasks()
        let runID = UUID()
        let task = Task { [weak self] in
            let started = Date(timeIntervalSince1970: TimeInterval(request.askedUnixSeconds))
            let until = Date(timeIntervalSince1970: TimeInterval(request.answerByUnixSeconds + 30))
            while !Task.isCancelled, Date() < until, self?.lease(id)?.state == .waiting {
                if let picked = try? await relay.fetchRelayBox(box: request.answerBoxID, key: request.answerBoxKey) {
                    var refused: String?
                    if let upload = try? Agentkeyring_V2_AnswerUpload(serializedBytes: picked.message) {
                        if case let .refused(reason)? = await self?.takeAnswer(upload, only: id) { refused = reason }
                    } else {
                        refused = "unreadable"
                    }
                    // Run cleanup in an uncancelled task so takeAnswer -> endPractice cancelling this reader never aborts the relay DELETE.
                    await Task { try? await relay.acknowledgeRelayBox(picked) }.value
                    guard let refused else { break }
                    KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "answer-refused", ["request": id, "reason": refused])
                    // A practice request is answered once, by its one device: it ends now. An agent's still
                    // waits in this Mac's panel, and its box is read on for another device's answer.
                    if self?.asks[id]?.leaseID == nil {
                        self?.endPractice(id, .unanswered, by: nil, reply: "")
                        break
                    }
                }
                try? await Task.sleep(for: RelayBoxProtocol.pollInterval(waited: Date().timeIntervalSince(started)))
            }
            if let self, !Task.isCancelled {
                self.askTasks[id]?.answer = nil
                if self.askTasks[id]?.isEmpty == true { self.askTasks.removeValue(forKey: id) }
            }
            _ = runID
        }
        entry.answer = task
        askTasks[id] = entry
    }

    /// The grant of an approved request, put once, even across restarts: a device's Stop marks it.
    private func putGrant(_ id: String) {
        guard askTasks[id]?.grant == nil, let request = asks[id]?.request else { return }
        let relay = environment.relay
        var entry = askTasks[id] ?? AskTasks()
        entry.grant = Task { [weak self] in
            defer {
                if let self {
                    self.askTasks[id]?.grant = nil
                    if self.askTasks[id]?.isEmpty == true { self.askTasks.removeValue(forKey: id) }
                }
            }
            do {
                try await relay.publishLeaseGrantBox(answerBox: request.answerBoxID, key: request.answerBoxKey, requestID: id)
                self?.asks[id]?.grantPut = true
                self?.noteGrantPut(id)
            } catch is CancellationError {
            } catch {
                self?.asks[id]?.grantPut = false
                KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "grant-not-put", ["request": id, "reason": "\(error)"])
            }
        }
        askTasks[id] = entry
    }

    private func noteGrantPut(_ id: String) {
        guard let leaseID = asks[id]?.leaseID else { return }
        do { try leaseStore.noteGrantPut(leaseID) } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "grant-not-noted", ["request": id, "reason": "\(error)"])
        }
    }

    /// Before every use of an approval its devices could stop: its grant must still stand. A Stop signed by a
    /// device in the list ends the lease for good; a relay that cannot say refuses this use only.
    public func checkNotStopped(lease leaseID: String) async throws {
        guard let (id, initialAsk) = asks.first(where: { $0.value.leaseID == leaseID }), !initialAsk.request.answerBoxID.isEmpty else {
            KeyringDiagnosticLog.mac.noteDeviceEvent("lease", "grant-not-read", ["lease": leaseID, "reason": "no pushed request for this lease"])
            throw AgentRPCError(.unavailable, MessageCopy.stopNotChecked)
        }
        await askTasks[id]?.grant?.value
        let ask = asks[id] ?? initialAsk
        let relay = environment.relay
        let state: (live: Bool, stop: Data?)
        do {
            if !ask.grantPut, !leaseStore.grantsPut.contains(leaseID) {
                try await relay.publishLeaseGrantBox(answerBox: ask.request.answerBoxID, key: ask.request.answerBoxKey, requestID: id)
                asks[id]?.grantPut = true
                noteGrantPut(id)
            }
            state = try await relay.readLeaseGrantBox(answerBox: ask.request.answerBoxID, key: ask.request.answerBoxKey, requestID: id)
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("lease", "grant-not-read", ["lease": leaseID, "reason": "\(error)"])
            throw AgentRPCError(.unavailable, MessageCopy.stopNotChecked)
        }
        if state.live { return }
        if let stop = state.stop, let (document, device) = fromDevice(stop), document.signerKeyID == device.replyKeyID,
           let end = try? Agentkeyring_V2_EndRequest(serializedBytes: document.payload), end.domain == "agentkeyring.end.v2",
           end.requestID == id, end.deviceKeyID == device.keyID {
            asks[id]?.endedBy = device.label
            _ = try? leaseStore.revoke(leaseID)
            KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "stopped", ["request": id, "device": device.label, "via": "grant"])
            throw AgentRPCError(.permissionDenied, MessageCopy.stoppedOn(device.label))
        }
        KeyringDiagnosticLog.mac.noteDeviceEvent("lease", "grant-refused", ["lease": leaseID])
        throw AgentRPCError(.unavailable, MessageCopy.stopNotChecked)
    }

    // MARK: Answers

    /// The first answer wins. A signed answer is checked against the members
    /// list as it is now: a device removed a moment ago is refused. A plain
    /// denial grants nothing and is taken from anyone who knows the request id
    /// and its box. `only`: the one request the answer may be for, the one whose box it came in.
    func takeAnswer(_ upload: Agentkeyring_V2_AnswerUpload, only id: String) async -> PeerIntakeOutcome {
        guard let members else { return .refused("This Mac has no list of devices yet.") }
        if !upload.denyRequestID.isEmpty {
            guard upload.denyRequestID == id, let ask = asks[id] else { return .refused("No request of this Mac's has that id.") }
            // Only the iPhone sends a plain denial: the Apple Watch always signs.
            let phone = members.devices.first { $0.kind == .iphone && (ask.request.forDeviceKeyID.isEmpty || $0.keyID == ask.request.forDeviceKeyID) }
            return record(id, choice: .deny, by: phone, reply: "", contents: nil)
        }
        guard let answer = try? Agentkeyring_V2_Answer(serializedBytes: upload.answer.payload), answer.domain == "agentkeyring.answer.v2",
            let ask = asks[id], CredentialSealing.sha256(ask.signed.payload) == answer.requestSha256 else {
            return .refused("No request of this Mac's has these exact bytes.")
        }
        let signer: Agentkeyring_V2_Device
        // A practice answer grants nothing: a device signs it with its reply key, as CredentialSealing.practiceAnswer takes it.
        do { signer = try CredentialSealing.verifySignedDocument(upload.answer, members: members, allowReplyKey: answer.choice == .deny || ask.leaseID == nil) } catch {
            return .refused("This answer is not signed by a device in the user's list of devices.")
        }
        if !ask.request.forDeviceKeyID.isEmpty, signer.keyID != ask.request.forDeviceKeyID {
            return .refused("Only the device a practice request is for may answer it.")
        }
        guard lease(id)?.state == .waiting else { return .taken }
        switch answer.choice {
        case .deny:
            return record(id, choice: .deny, by: signer, reply: answer.reply, contents: nil)
        case .approve where ask.leaseID == nil:
            return record(id, choice: .approve, by: signer, reply: "", contents: nil)
        case .approve:
            var approval = Agentkeyring_V2_Approval()
            approval.request = ask.signed.payload
            approval.answer = upload.answer
            approval.delivery = upload.delivery
            do {
                let contents = try CredentialSealing.openDelivery(approval, members: members, with: keys.receiving)
                return record(id, choice: .approve, by: signer, reply: "", contents: contents)
            } catch {
                return .refused("This approval does not open for this request, or has run out.")
            }
        default:
            return .refused("An answer approves or denies.")
        }
    }

    /// Records the first answer, in the lease store for an agent's request.
    private func record(_ id: String, choice: Agentkeyring_V2_Choice, by device: Agentkeyring_V2_Device?, reply: String,
        contents: Agentkeyring_V2_DeliveryContents?) -> PeerIntakeOutcome {
        guard let ask = asks[id], lease(id)?.state == .waiting else { return .taken }
        guard let leaseID = ask.leaseID else {
            endPractice(id, choice == .approve ? .approved : .denied, by: device, reply: reply)
            return .taken
        }
        let by: Agentkeyring_V2_DeviceKind = switch device?.kind {
        case .watch?: .watch
        case .mac?: .mac
        case .iphone?, .unspecified?, .UNRECOGNIZED?, nil: .iphone
        }
        asks[id]?.answeredBy = device?.label ?? ""
        do {
            if let contents { try leaseStore.approveFromDevices(leaseID, contents: contents, by: by) }
            else { _ = try leaseStore.denyLease(leaseID, reply: reply, decidedOn: by) }
        } catch {
            return .refused("The Mac could not record the answer.")
        }
        return .taken
    }
}
#endif
