// Written by AI on 2026.11.21 by model claude opus 5.5, from the relay's
// requests (internal/relay/requests.go, push.go, watch.go).
//
// This Mac as the computer that asks, for its own agents' requests and for
// practice requests: it writes and signs each request naming its own door,
// pushes it to the iPhone and Apple Watch through Apple, and takes their
// answers, arrival notes and Stop at the door. For an agent's request the
// lease store is the record (CredentialLeaseStore): the first answer wins
// there against this Mac's own panel, and its hold after a denial applies.
// Every outcome goes to the devices as a silent push.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation

@MainActor
extension MacDevice {
    /// One request this Mac pushed.
    struct Ask {
        /// The Request bytes and this Mac's signature over them.
        let signed: Agentkeyring_V2_Signed
        let request: Agentkeyring_V2_Request
        /// An agent's lease; nil for a practice request.
        let leaseID: String?
        /// A practice request a device asked for: that device, which hears its outcome too.
        var askedBy: String?
        var pushed: Int64 = 0
        var arrived: Int64 = 0
        var arrivedOn = ""
        var answeredBy = ""
        var endedBy = ""
        /// A practice request's own state, and his words if he denied it.
        var practice = Agentkeyring_V2_LeaseState.waiting
        var reply = ""
        /// The last state the devices were told of.
        var told = Agentkeyring_V2_LeaseState.waiting
    }

    /// Whether an agent's request on this Mac can also go to the iPhone and Apple Watch now, and if not, why.
    public var devicesUnreachable: String? {
        guard members?.devices.contains(where: { $0.kind == .iphone || $0.kind == .watch }) == true else { return MessageCopy.noIPhoneOrWatch }
        switch door {
        case .noTailscale: return MessageCopy.noTailscale
        case let .failed(reason): return MessageCopy.doorClosed(reason)
        case .opening: return MessageCopy.doorClosed("it is still opening")
        case .open: break
        }
        return push == nil ? MessageCopy.noPushKey : nil
    }

    static func newID() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    /// Cuts a claim to `limit` bytes on a character boundary, so the push still fits Apple's 4 KB.
    static func fitted(_ text: String, _ limit: Int) -> String {
        var text = text
        while text.utf8.count > limit { text.removeLast() }
        return text
    }

    private func signed(_ request: Agentkeyring_V2_Request) throws -> Agentkeyring_V2_Signed {
        try Sealing.signed(request.serializedData(), by: keys.machineID) { try keys.tls.sign($0) }
    }

    private func newRequest(id: String, answerBy: Int64) throws -> Agentkeyring_V2_Request {
        guard case let .open(host, port, _) = door else { throw RelayFailure(.unavailable, devicesUnreachable ?? MessageCopy.noTailscale) }
        var request = Agentkeyring_V2_Request()
        request.domain = "agentkeyring.request.v2"
        request.requestID = id
        request.machineID = keys.machineID
        request.askedUnixSeconds = Int64(Date().timeIntervalSince1970)
        request.answerByUnixSeconds = answerBy
        request.answerAddress = Tailnet.join(host, port)
        request.answerTlsPublicKey = keys.tls.publicKeySPKI
        return request
    }

    // MARK: An agent's request

    /// An agent on this Mac asked and its lease waits: the request also goes to
    /// the iPhone and Apple Watch. This Mac never waits for them: if they cannot
    /// be reached, the request is shown here alone, and the log says why.
    public func ask(for lease: Agentkeyring_V1_Lease, agent: String, project: String) {
        if let why = devicesUnreachable {
            DiagnosticLog.record("devices", "not-asked", ["lease": lease.leaseID, "reason": why])
            return
        }
        do {
            var request = try newRequest(id: Self.newID(), answerBy: lease.pendingUntilUnixSeconds)
            request.loginID = lease.loginID
            request.reason = Self.fitted(lease.reason, 400)
            request.agent = Self.fitted(agent, 100)
            request.project = Self.fitted(project, 100)
            request.task = Self.fitted(lease.taskRef, 100)
            let document = try signed(request)
            try leaseStore.notePushed(lease.leaseID, request: document.serializedData())
            asks[request.requestID] = Ask(signed: document, request: request, leaseID: lease.leaseID)
            DiagnosticLog.record("devices", "asked", ["lease": lease.leaseID, "request": request.requestID, "login": lease.loginID])
            enqueuePushes(request.requestID, waiting: true)
        } catch {
            DiagnosticLog.record("devices", "not-asked", ["lease": lease.leaseID, "reason": "\(error)"])
        }
    }

    /// After a restart: every lease whose request went to the devices is followed again, so their answers are still taken.
    func resumeAsks() {
        for (leaseID, bytes) in leaseStore.pushedRequests {
            guard let document = try? Agentkeyring_V2_Signed(serializedBytes: bytes),
                let request = try? Sealing.parseRequest(document.payload) else { continue }
            let pending = (try? leaseStore.get(leaseID))?.state == .pending
            // A lease that ended while the app was closed is told to the devices once.
            asks[request.requestID] = Ask(signed: document, request: request, leaseID: leaseID, told: pending ? .waiting : .unspecified)
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
            if lease.state != .waiting, lease.state != ask.told {
                asks[id]?.told = lease.state
                enqueuePushes(id, waiting: false)
            }
            if ![.waiting, .approved].contains(lease.state) { try? leaseStore.forgetPushed(leaseID) }
        }
        askSignal.fire()
    }

    /// The request as the devices see it, from the lease store for an agent's, or its own record for a practice request.
    func lease(_ id: String) -> Agentkeyring_V2_Lease? {
        guard let ask = asks[id] else { return nil }
        var lease = Agentkeyring_V2_Lease()
        lease.requestID = id
        lease.loginID = ask.request.loginID
        lease.answerByUnixSeconds = ask.request.answerByUnixSeconds
        lease.pushedUnixSeconds = ask.pushed
        lease.arrivedUnixSeconds = ask.arrived
        lease.arrivedOn = ask.arrivedOn
        lease.answeredBy = ask.answeredBy
        guard let leaseID = ask.leaseID else {
            lease.state = ask.practice
            lease.reply = ask.reply
            return lease
        }
        guard let local = try? leaseStore.get(leaseID) else { return nil }
        lease.state = switch local.state {
        case .pending: .waiting
        case .active: .approved
        case .denied: .denied
        case .unanswered: .unanswered
        case .cancelled: .cancelled
        default: .ended // Released, out of time, or stopped.
        }
        lease.notAfterUnixSeconds = local.notAfterUnixSeconds
        lease.reply = local.reply
        lease.retryNotBeforeUnixSeconds = local.retryNotBeforeUnixSeconds
        if ask.answeredBy.isEmpty, local.approvedBy == .mac, local.state != .pending, local.state != .cancelled, local.state != .unanswered {
            lease.answeredBy = keys.label // Answered in this Mac's own panel.
        }
        if local.state == .revoked { lease.endedBy = ask.endedBy.isEmpty ? keys.label : ask.endedBy }
        return lease
    }

    // MARK: Practice

    /// A practice request on another device of Josh's: it arrives there like a
    /// real one, and this ends when that device answers or ten minutes pass.
    /// `progress` hears each step on the way (sent, with Apple, arrived).
    public func practice(on deviceKeyID: String, progress: @MainActor (Agentkeyring_V2_Lease) -> Void) async throws -> Agentkeyring_V2_Lease {
        let id = try makePractice(for: deviceKeyID, id: Self.newID(), askedBy: nil)
        var last = Agentkeyring_V2_Lease()
        while true {
            guard let lease = lease(id) else { throw RelayFailure(.notFound, MessageCopy.somethingWentWrong) }
            if lease != last { progress(lease); last = lease }
            if lease.state != .waiting { return lease }
            await askSignal.wait(until: .now + .seconds(30))
            try Task.checkCancellation()
        }
    }

    /// Makes and pushes a practice request for one device, or returns the one
    /// already waiting for it: the same id again rejoins, and there is at most one per device.
    func makePractice(for target: String, id: String, askedBy: String?) throws -> String {
        guard let device = members?.devices.first(where: { $0.keyID == target }), target != keys.deviceKeyID else {
            throw RelayFailure(.notFound, MessageCopy.noIPhoneOrWatch)
        }
        if let existing = asks[id], existing.request.forDeviceKeyID == target { return id }
        if let waiting = asks.first(where: { $0.value.request.forDeviceKeyID == target && $0.value.practice == .waiting && $0.value.leaseID == nil })?.key {
            return waiting
        }
        if case .open = door, push == nil { throw RelayFailure(.unavailable, MessageCopy.noPushKey) }
        guard registration(for: target) != nil else { throw RelayFailure(.unavailable, MessageCopy.noPushAddress(device.label)) }
        var request = try newRequest(id: id, answerBy: Int64(Date().timeIntervalSince1970) + 600)
        request.reason = "You asked me to download October’s invoice."
        request.agent = "Agent Keyring"
        request.project = "Practice"
        request.forDeviceKeyID = target
        asks[id] = Ask(signed: try signed(request), request: request, leaseID: nil, askedBy: askedBy)
        DiagnosticLog.record("practice", "sent", ["request": id, "device": device.label])
        enqueuePushes(id, waiting: true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            self?.endPractice(id, .unanswered, by: nil, reply: "")
        }
        return id
    }

    private func endPractice(_ id: String, _ state: Agentkeyring_V2_LeaseState, by device: Agentkeyring_V2_Device?, reply: String) {
        guard asks[id]?.practice == .waiting else { return }
        asks[id]?.practice = state
        asks[id]?.reply = reply
        asks[id]?.answeredBy = device?.label ?? ""
        asks[id]?.told = state
        DiagnosticLog.record("practice", "answered", ["request": id, "state": "\(state)"])
        enqueuePushes(id, waiting: false)
        askSignal.fire()
    }

    func takePracticeAsk(_ body: Data) -> DoorReply {
        guard let (document, asker) = fromDevice(body), let ask = try? Agentkeyring_V2_PracticeAsk(serializedBytes: document.payload),
            ask.domain == "agentkeyring.practice.v2" else {
            return .refused(403, "A practice ask is signed by a device in the list of devices.")
        }
        let target = ask.forDeviceKeyID.isEmpty ? asker.keyID : ask.forDeviceKeyID
        guard target == asker.keyID || asker.kind == .iphone || asker.kind == .mac else {
            return .refused(403, "A device asks for its own practice request; the iPhone may also ask for its Apple Watch's.")
        }
        guard ask.requestID.count == 32, ask.requestID.allSatisfy(\.isHexDigit), ask.requestID == ask.requestID.lowercased() else {
            return .refused(400, "A practice request's id is 32 lowercase hex digits.")
        }
        if target == keys.deviceKeyID {
            onPracticeHere?()
            return .text(ask.requestID)
        }
        do { return .text(try makePractice(for: target, id: ask.requestID, askedBy: asker.keyID)) } catch {
            return .refused(503, (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: Pushes

    /// One request's pushes go one at a time, each with the state as it is
    /// then: a request ended at once must not leave its alert arriving after the push that clears it.
    func enqueuePushes(_ id: String, waiting: Bool) {
        let previous = pushChains[id]
        pushChains[id] = Task { [weak self] in
            await previous?.value
            await self?.sendPushes(id, waiting: waiting)
        }
    }

    private func sendPushes(_ id: String, waiting: Bool) async {
        guard let push, let ask = asks[id], let members else { return }
        let outcome = waiting ? nil : lease(id)
        var targets = members.devices.filter { device in
            device.keyID != keys.deviceKeyID && (ask.request.forDeviceKeyID.isEmpty || device.keyID == ask.request.forDeviceKeyID)
        }
        if !waiting, let asker = ask.askedBy, let device = members.devices.first(where: { $0.keyID == asker }), asker != keys.deviceKeyID,
            !targets.contains(where: { $0.keyID == asker }) {
            targets.append(device)
        }
        let copies = waiting ? ((try? await store.sealed()) ?? []) : []
        for device in targets {
            guard let registration = registration(for: device.keyID),
                let noticeKey = try? P256.KeyAgreement.PublicKey(x963Representation: registration.noticePublicKey) else { continue }
            var work = Agentkeyring_V2_Work()
            work.request = ask.signed.payload
            work.requestSignature = ask.signed.signature
            work.login = login(for: ask.request)
            if let outcome { work.outcome = outcome }
            if waiting, device.kind == .watch, let listed = catalogue?.logins.first(where: { $0.loginID == ask.request.loginID }),
                let copy = copies.first(where: { $0.openerID == device.keyID && $0.loginID == listed.loginID && $0.version == listed.version }) {
                work.sealedLogin = copy
            }
            guard var notice = try? Sealing.sealNotice(work, to: noticeKey, deviceKeyID: device.keyID) else { continue }
            var payload = PushPayload.request(id: id, notice: notice, waiting: waiting)
            if payload.count > PushPayload.largest, work.hasSealedLogin {
                // Too big for Apple with the copy in it: the Watch can still see and deny it.
                work.clearSealedLogin()
                notice = (try? Sealing.sealNotice(work, to: noticeKey, deviceKeyID: device.keyID)) ?? notice
                payload = PushPayload.request(id: id, notice: notice, waiting: waiting)
                DiagnosticLog.record("push", "copy-left-out", ["request": id, "device": device.label, "bytes": "\(payload.count)"])
            }
            do {
                try await push.send(payload, to: registration, collapseID: id, expiration: ask.request.answerByUnixSeconds, visible: waiting)
                if waiting, asks[id]?.pushed == 0 {
                    asks[id]?.pushed = Int64(Date().timeIntervalSince1970)
                    askSignal.fire()
                }
                DiagnosticLog.record("push", "accepted", ["request": id, "device": device.label, "visible": "\(waiting)"])
            } catch let failure as ApplePush.Failure where failure.invalidToken {
                saved.registrations.removeValue(forKey: device.keyID)
                persist()
                DiagnosticLog.record("push", "address-gone", ["device": device.label, "reason": failure.reason])
            } catch {
                DiagnosticLog.record("push", "not-sent", ["request": id, "device": device.label, "reason": "\(error)"])
            }
        }
    }

    /// The password a push names, from the signed catalogue; a practice request names example.com.
    private func login(for request: Agentkeyring_V2_Request) -> Agentkeyring_V2_Login {
        if !request.forDeviceKeyID.isEmpty {
            var practice = Agentkeyring_V2_Login()
            practice.title = "example.com"
            practice.sites = ["example.com"]
            practice.account = "you@example.com"
            return practice
        }
        return catalogue?.logins.first { $0.loginID == request.loginID } ?? Agentkeyring_V2_Login()
    }

    // MARK: The answer door

    /// The first answer wins. A signed answer is checked against the members
    /// list as it is now: a device removed a moment ago is refused. A plain
    /// denial grants nothing and is taken from anyone who knows the request id.
    func takeAnswer(_ body: Data) async -> DoorReply {
        guard let upload = try? Agentkeyring_V2_AnswerUpload(serializedBytes: body) else { return .refused(400, "The body must be an AnswerUpload.") }
        guard let members else { return .refused(403, "This Mac has no list of devices yet.") }
        if !upload.denyRequestID.isEmpty {
            let id = upload.denyRequestID
            guard let ask = asks[id] else { return .refused(403, "No request of this Mac's has that id.") }
            // Only the iPhone sends a plain denial: the Apple Watch always signs.
            let phone = members.devices.first { $0.kind == .iphone && (ask.request.forDeviceKeyID.isEmpty || $0.keyID == ask.request.forDeviceKeyID) }
            return record(id, choice: .deny, by: phone, reply: "", contents: nil)
        }
        guard let answer = try? Agentkeyring_V2_Answer(serializedBytes: upload.answer.payload), answer.domain == "agentkeyring.answer.v2",
            let id = asks.first(where: { Sealing.sha256($0.value.signed.payload) == answer.requestSha256 })?.key, let ask = asks[id] else {
            return .refused(403, "No request of this Mac's has these exact bytes.")
        }
        let signer: Agentkeyring_V2_Device
        do { signer = try Sealing.verify(upload.answer, members: members, allowReplyKey: answer.choice == .deny) } catch {
            return .refused(403, "This answer is not signed by a device in the user's list of devices.")
        }
        if !ask.request.forDeviceKeyID.isEmpty, signer.keyID != ask.request.forDeviceKeyID {
            return .refused(403, "Only the device a practice request is for may answer it.")
        }
        guard lease(id)?.state == .waiting else { return .ok(message(lease(id) ?? Agentkeyring_V2_Lease())) }
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
                let contents = try Sealing.openDelivery(approval, members: members, with: keys.receiving)
                return record(id, choice: .approve, by: signer, reply: "", contents: contents)
            } catch {
                return .refused(403, "This approval does not open for this request, or has run out.")
            }
        default:
            return .refused(400, "An answer approves or denies.")
        }
    }

    /// Records the first answer, in the lease store for an agent's request, and replies with the request as it now stands.
    private func record(_ id: String, choice: Agentkeyring_V2_Choice, by device: Agentkeyring_V2_Device?, reply: String,
        contents: Agentkeyring_V2_DeliveryContents?) -> DoorReply {
        guard let ask = asks[id], lease(id)?.state == .waiting else { return .ok(message(lease(id) ?? Agentkeyring_V2_Lease())) }
        guard let leaseID = ask.leaseID else {
            endPractice(id, choice == .approve ? .approved : .denied, by: device, reply: reply)
            return .ok(message(lease(id) ?? Agentkeyring_V2_Lease()))
        }
        let by: Agentkeyring_V1_ApprovedBy = switch device?.kind {
        case .watch?: .watch
        case .mac?: .mac
        default: .iphone
        }
        asks[id]?.answeredBy = device?.label ?? ""
        do {
            if let contents { try leaseStore.approveFromDevices(leaseID, contents: contents, by: by) }
            else { _ = try leaseStore.deny(leaseID, reply: reply, approvedBy: by) }
        } catch {
            return .refused(503, "The Mac could not record the answer. Try again.")
        }
        return .ok(message(lease(id) ?? Agentkeyring_V2_Lease()))
    }

    /// A note that a request reached a device, for the screens to say so: signed
    /// by the device's reply key, or unsigned, naming the SHA-256 of the push
    /// address this Mac sent it to, which a locked iPhone's extension can give.
    func takeArrival(_ body: Data) -> DoorReply {
        guard let members, let document = try? Agentkeyring_V2_Signed(serializedBytes: body),
            let arrival = try? Agentkeyring_V2_Arrival(serializedBytes: document.payload), arrival.domain == "agentkeyring.arrival.v2" else {
            return .refused(400, "The body must be a signed Arrival.")
        }
        let device: Agentkeyring_V2_Device
        if let signer = try? Sealing.verify(document, members: members, allowReplyKey: true) {
            device = signer
        } else if let named = members.devices.first(where: { $0.keyID == arrival.deviceKeyID }), let registration = registration(for: named.keyID),
            !arrival.pushTokenSha256.isEmpty, arrival.pushTokenSha256 == Sealing.sha256(registration.apnsToken) {
            device = named
        } else {
            return .refused(403, "An arrival is signed by the device it reached, or names its push address.")
        }
        guard arrival.deviceKeyID == device.keyID else { return .refused(403, "An arrival comes from the device it reached.") }
        guard let ask = asks[arrival.requestID], ask.request.forDeviceKeyID.isEmpty || ask.request.forDeviceKeyID == device.keyID else {
            return .refused(404, "No request of this Mac's has that id.")
        }
        if ask.arrived == 0 {
            asks[arrival.requestID]?.arrived = Int64(Date().timeIntervalSince1970)
            asks[arrival.requestID]?.arrivedOn = device.label
            DiagnosticLog.record("devices", "arrived", ["request": arrival.requestID, "device": device.label])
            askSignal.fire()
        }
        return .ok()
    }

    /// Stop: a device ends an approval of this Mac's agent at once.
    func takeEnd(_ body: Data) -> DoorReply {
        guard let (document, device) = fromDevice(body), let end = try? Agentkeyring_V2_EndRequest(serializedBytes: document.payload),
            end.domain == "agentkeyring.end.v2", end.deviceKeyID == device.keyID else {
            return .refused(403, "Stop is signed by a device in the user's list of devices.")
        }
        guard let ask = asks[end.requestID], let leaseID = ask.leaseID else { return .refused(404, "No request of this Mac's has that id.") }
        if (try? leaseStore.get(leaseID))?.state == .active {
            asks[end.requestID]?.endedBy = device.label
            _ = try? leaseStore.revoke(leaseID)
            DiagnosticLog.record("devices", "stopped", ["request": end.requestID, "device": device.label])
        }
        return .ok(message(lease(end.requestID) ?? Agentkeyring_V2_Lease()))
    }
}
