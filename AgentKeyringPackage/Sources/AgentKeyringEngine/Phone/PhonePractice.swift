// Written by AI on 2026.11.24 by model claude opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Practice requests this iPhone makes itself, with no Mac (keyring.proto,
// Request.asker_key_id): for this iPhone during first run and from Home, for
// its Apple Watch (also when the Watch asks), and for the Mac from Devices.
// Each is signed with this iPhone's reply key, names no login and no machine,
// is pushed through the relay like any request, and is answered in its own box,
// which this iPhone reads; then the device it was for is told how it ended.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

extension PhoneKeyringEngine {
    /// Makes and pushes a practice request for `target` (this iPhone, its Watch or the Mac), and reads its
    /// answer box in the background. Returns its id once Apple has it.
    func originatePractice(for target: String, id: String) async throws -> String {
        guard let me = state.deviceKeyID, let members, let device = members.devices.first(where: { $0.keyID == target }) else {
            throw PhoneApprovalError.notAllowed("That device is not in the list.")
        }
        let now = Int64(Date().timeIntervalSince1970)
        if let waiting = practiceAsks[id],
           let parsed = try? CredentialSealing.parseRequest(waiting.request),
           parsed.forDeviceKeyID == target,
           parsed.answerByUnixSeconds > now {
            return id
        }
        guard let registration = pushRegistration(for: target),
              let noticeKey = try? P256.KeyAgreement.PublicKey(x963Representation: registration.noticePublicKey) else {
            throw PhoneApprovalError.notAllowed("That device has no push address yet.")
        }
        // Rejoin an unexpired practice request saved before a relaunch rather than making a
        // second request with a different box under the same id.
        let envelope: Agentkeyring_V2_SignedRequestEnvelope
        if target == me,
           let saved = state.requestEnvelopes[id].flatMap({ try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) }),
           !saved.hasOutcome,
           let parsed = try? CredentialSealing.parseRequest(saved.request),
           parsed.forDeviceKeyID == target,
           parsed.answerByUnixSeconds > now {
            envelope = saved
        } else {
            var made = try CredentialSealing.practiceRequest(id: id, for: target, by: me, signReply: keys.signReply)
            made.login = Self.practiceLogin
            envelope = made
        }
        let request = try CredentialSealing.parseRequest(envelope.request)
        let notice = try CredentialSealing.sealNotice(envelope, to: noticeKey, deviceKeyID: target)
        let endBackground = PhoneBackgroundTime.begin("A practice request")
        defer { endBackground() }
        // A Mac shows a waiting request in its own panel: its push is silent.
        let visible = device.kind != .mac
        try await pusher.sendPush(PushPayload.pushRequest(id: id, notice: notice, waiting: visible, for: device.kind), to: registration, collapseID: id,
                                   expiration: request.answerByUnixSeconds, visible: visible)
        // Keep this iPhone's own practice request in state.requestEnvelopes without going through receive(),
        // so only a real push reports arrival while Answer It Here works if the push times out.
        if target == me {
            let encoded = try envelope.serializedData()
            if state.requestEnvelopes[id] != encoded {
                var next = state
                next.requestEnvelopes[id] = encoded
                save(next)
            }
        }
        practiceAsks[id] = envelope
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "pushed", ["request": id, "device": String(target.prefix(16))])
        readPracticeBox(envelope, target: target)
        return id
    }

    static var practiceLogin: Agentkeyring_V2_Login {
        var login = Agentkeyring_V2_Login()
        login.title = "example.com"
        login.sites = ["example.com"]
        login.account = "you@example.com"
        return login
    }

    /// A device's newest push registration this iPhone holds: its own, its Watch's, or the Mac's from iCloud.
    func pushRegistration(for deviceKeyID: String) -> Agentkeyring_V2_PushRegistration? {
        state.pushRegistrations[deviceKeyID].flatMap { try? SignedDocument(serializedBytes: $0) }
            .flatMap { try? Agentkeyring_V2_PushRegistration(serializedBytes: $0.payload) }
    }

    /// Immediately settles a practice request that this iPhone originated for itself once its answer
    /// has been accepted by the relay, so the result screen appears without waiting to poll our own box.
    func settleOwnPractice(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, upload: AnswerUpload) {
        guard let me = state.deviceKeyID, let members,
              let request = try? CredentialSealing.parseRequest(envelope.request),
              request.askerKeyID == me, request.forDeviceKeyID == me,
              let outcome = CredentialSealing.practiceAnswer(upload, for: envelope, target: me, members: members) else { return }
        let id = request.requestID
        practiceAsks[id] = nil
        practiceBoxTasks[id]?.cancel()
        practiceBoxTasks[id] = nil
        var ended = envelope
        ended.outcome = outcome
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "ended", ["request": id, "state": "\(outcome.state)"])
        receive(ended, allowRefresh: false)
        practiceEnded[me] = outcome
        publish()
    }

    /// Reads the practice request's box until it is answered or its ten minutes pass, then tells the device
    /// it was for how it ended (this iPhone takes the outcome itself).
    private func readPracticeBox(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, target: String) {
        guard let request = try? CredentialSealing.parseRequest(envelope.request), let relay = RelayBoxClient(for: request) else { return }
        let id = request.requestID
        practiceBoxTasks[id]?.cancel()
        practiceBoxTasks[id] = Task { [weak self] in
            let started = Date()
            let until = Date(timeIntervalSince1970: TimeInterval(request.answerByUnixSeconds + 30))
            var outcome: Agentkeyring_V2_Lease?
            while outcome == nil, Date() < until, !Task.isCancelled {
                if let picked = try? await relay.fetchRelayBox(box: request.answerBoxID, key: request.answerBoxKey) {
                    if let self, let members = self.members, let upload = try? AnswerUpload(serializedBytes: picked.message) {
                        outcome = CredentialSealing.practiceAnswer(upload, for: envelope, target: target, members: members)
                        if outcome == nil { KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "answer refused", ["request": id]) }
                    }
                    try? await relay.acknowledgeRelayBox(picked)
                    if outcome != nil { break }
                }
                try? await Task.sleep(for: RelayBoxProtocol.pollInterval(waited: Date().timeIntervalSince(started)))
            }
            guard let self, !Task.isCancelled else { return }
            self.practiceBoxTasks[id] = nil
            self.practiceAsks[id] = nil
            var ended = envelope
            ended.outcome = outcome ?? {
                var lease = Agentkeyring_V2_Lease()
                lease.requestID = id
                lease.state = .unanswered
                lease.answerByUnixSeconds = request.answerByUnixSeconds
                return lease
            }()
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "ended", ["request": id, "state": "\(ended.outcome.state)"])
            if target == self.state.deviceKeyID {
                self.receive(ended, allowRefresh: false)
            } else if let registration = self.pushRegistration(for: target),
                      let key = try? P256.KeyAgreement.PublicKey(x963Representation: registration.noticePublicKey),
                      let notice = try? CredentialSealing.sealNotice(ended, to: key, deviceKeyID: target) {
                let targetKind = self.members?.devices.first(where: { $0.keyID == target })?.kind ?? .unspecified
                let alertTransport = PushPayload.usesAlertTransport(waiting: false, for: targetKind)
                try? await self.pusher.sendPush(PushPayload.pushRequest(id: id, notice: notice, waiting: false, for: targetKind), to: registration, collapseID: id,
                                            expiration: Int64(Date().timeIntervalSince1970) + 3600, visible: alertTransport)
            }
            self.practiceEnded[target] = ended.outcome
            self.publish()
        }
    }
}

@MainActor
extension PhoneKeyringEngine {
    // MARK: Practice

    /// The practice request while first run has it open.
    var practiceOpen: AccessRequest? {
        guard case let .practice(id) = firstRun else { return nil }
        return practiceEnvelope(id).flatMap { envelope in (try? CredentialSealing.parseRequest(envelope.request)).map(Self.practiceRequest) }
    }

    /// The practice request in the real request's layout, with the board's words.
    nonisolated static func practiceRequest(_ request: KeyringRequest) -> AccessRequest {
        PhoneNoticeDecoder.practiceRequest(request)
    }

    /// This iPhone's practice request with this id, as this iPhone last heard of it.
    func practiceEnvelope(_ id: String) -> Agentkeyring_V2_SignedRequestEnvelope? {
        state.requestEnvelopes[id].flatMap { try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) }.flatMap { isPracticeEnvelope($0) ? $0 : nil }
    }

    /// The practice request for this iPhone still waiting for an answer, if any: one at most.
    var waitingPractice: Agentkeyring_V2_SignedRequestEnvelope? {
        let now = Date()
        return state.requestEnvelopes.values.compactMap { try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) }.first { envelope in
            isPracticeEnvelope(envelope) && CredentialRequestLifecycle.isWaiting(envelope, now: now)
        }
    }

    func isPracticeEnvelope(_ envelope: Agentkeyring_V2_SignedRequestEnvelope) -> Bool {
        guard let members, let mine = state.deviceKeyID else { return false }
        // Only cryptographically verified practice requests pass verifySignedLeaseRequest returning nil.
        do {
            return (try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: mine)) == nil
        } catch {
            return false
        }
    }

    nonisolated static func outcome(_ state: Agentkeyring_V2_LeaseState) -> PhonePracticeOutcome {
        switch state {
        case .approved, .ended, .expired, .released: .approved
        case .denied: .denied
        case .cancelled, .unanswered, .waiting, .unspecified, .UNRECOGNIZED: .noAnswer
        }
    }

    func devicePracticeStatus(for deviceKeyID: String) -> PhoneDevice.PracticeStatus? {
        let now = Int64(Date().timeIntervalSince1970)
        if practiceAsks.values.contains(where: { envelope in
            guard let parsed = try? CredentialSealing.parseRequest(envelope.request) else { return false }
            return parsed.forDeviceKeyID == deviceKeyID && parsed.answerByUnixSeconds > now
        }) {
            return deviceKeyID == state.deviceKeyID ? .waitingHere : .withApple
        }
        guard let ended = practiceEnded[deviceKeyID] else { return nil }
        switch ended.state {
        case .approved, .ended, .expired, .released: return .approved
        case .denied: return .denied
        case .unanswered, .cancelled: return .noAnswer
        case .waiting, .unspecified, .UNRECOGNIZED: return nil
        }
    }

    /// Single idempotent driver for first-run practice side effects: timer, push registration, and sending.
    func syncPractice(resetTimer: Bool = false) {
        guard state.deviceKeyID != nil else { return }
        switch firstRun {
        case let .practiceWaiting(id, false):
            if resetTimer || practiceTimer == nil { startPracticeTimer() }
            if pushRegistered {
                if practiceTask == nil { askForPractice(id) }
            } else {
                ensurePushRegistration()
            }
        case let .settingUpNotifications(id):
            if pushRegistered {
                if practiceTask == nil { askForPractice(id) }
            } else {
                ensurePushRegistration()
            }
        default:
            break
        }
    }

    /// First run waits for the practice request: 30 seconds, then the screen says why it hasn't come.
    private func startPracticeTimer() {
        practiceTimer?.cancel()
        practiceTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            self.practiceTimer = nil
            self.apply(.practiceTimedOut(pushAddress: self.pushRegistered))
        }
    }


    /// Makes this iPhone's practice request, by its id: the same id again rejoins it. It arrives pushed,
    /// like any request, which shows that requests reach the phone, with no Mac needed. If it cannot be
    /// pushed, first run says so.
    func askForPractice(_ id: String) {
        practiceTask?.cancel()
        practiceTask = Task { [weak self] in
            defer { self?.practiceTask = nil }
            guard let self, let mine = self.state.deviceKeyID else { return }
            do {
                let made = try await self.originatePractice(for: mine, id: id)
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "made", ["request": made])
                self.apply(.practiceSent(id: made))
            } catch is CancellationError {
            } catch {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "not made", ["error": "\(error)"])
                self.apply(.practiceMacUnreachable)
            }
        }
    }


    /// First run's practice request, approved with one Face ID: a signed answer with no delivery.
    func approvePractice(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, reusingUnlock: Bool = false) async throws {
        guard let members, let keyID = state.deviceKeyID,
              (try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keyID)) == nil else {
            throw PhoneApprovalError.notAllowed("This practice request could not be verified.")
        }
        let parsed = try CredentialSealing.parseRequest(envelope.request)
        guard CredentialRequestLifecycle.isWaiting(envelope) else {
            PhoneDeliveredNotifications.removeRequestNotification(parsed.requestID)
            throw PhoneApprovalError.notAllowed("This request has already timed out.")
        }
        let context = LAContext()
        defer { context.invalidate() }
        if reusingUnlock { context.touchIDAuthenticationAllowableReuseDuration = 10 }
        try await keys.authorize(context, reason: PhoneCopy.faceIDPractice)
        if settled(parsed.requestID) { return PhoneDeliveredNotifications.removeRequestNotification(parsed.requestID) }
        guard let freshMembers = self.members, let freshKeyID = state.deviceKeyID,
              let freshEnvelope = practiceEnvelope(parsed.requestID), freshEnvelope.request == envelope.request,
              CredentialRequestLifecycle.isWaiting(freshEnvelope),
              (try CredentialSealing.verifySignedLeaseRequest(freshEnvelope, members: freshMembers, ownKeyID: freshKeyID)) == nil else {
            throw PhoneApprovalError.notAllowed("This practice request is no longer valid.")
        }
        var answer = Agentkeyring_V2_Answer()
        answer.domain = "agentkeyring.answer.v2"
        answer.requestSha256 = CredentialSealing.sha256(envelope.request)
        answer.choice = .approve
        answer.decidedUnixSeconds = Int64(Date().timeIntervalSince1970)
        answer.notAfterUnixSeconds = answer.decidedUnixSeconds + 60
        var upload = AnswerUpload()
        upload.answer = try CredentialSealing.signedDocument(answer.serializedData(), by: CredentialSealing.keyID(keys.signingPublicKey())) { try keys.signWithDeviceKey($0, context: context) }
        if try await send(upload, for: envelope, approving: true) {
            settleOwnPractice(envelope, upload: upload)
        }
        await sealMissingWatchCopies(context: context)
    }

    /// Send Practice Request on Home, or Practice on Apple Watch's row. For this iPhone, the one already
    /// waiting is returned to be shown again instead of a second being made.
    public func sendPracticeRequest(to deviceID: String?) async -> String? {
        guard let deviceID, deviceID != state.deviceKeyID else {
            if let waiting = waitingPractice, let id = try? CredentialSealing.parseRequest(waiting.request).requestID { return id }
            guard let mine = state.deviceKeyID else { return nil }
            do { _ = try await originatePractice(for: mine, id: PhoneFirstRun.newPracticeID()) }
            catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "not made", ["error": "\(error)"]) }
            return nil
        }
        do { _ = try await originatePractice(for: deviceID, id: PhoneFirstRun.newPracticeID()) }
        catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "not made", ["device": String(deviceID.prefix(16)), "error": "\(error)"]) }
        return nil
    }
}
