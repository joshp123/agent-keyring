// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Requests: how they arrive (pushes and notices), where this iPhone is woken (push registration), how it
// answers them, and how the screens and the notification service extension show them.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UserNotifications

@MainActor
extension PhoneKeyringEngine {
    // MARK: Pushes

    /// Any push or notification this app sees: a request's or an outcome's notice, or the Mac's silent
    /// "something changed", which has this iPhone read iCloud. The request's envelope is in the notice; nothing is fetched to learn of it.
    public func received(_ userInfo: [AnyHashable: Any], pushDelivered: Bool = false) async {
        if !state.pushSeen { var next = state; next.pushSeen = true; save(next) }
        if userInfo["rev"] != nil { await refresh() }
        if let envelope = openNotice(userInfo) {
            let expected: Bool? = pushDelivered ? true : nil
            if !receive(envelope, allowRefresh: false, pushExpected: expected), await refresh() {
                _ = receive(envelope, allowRefresh: false, pushExpected: expected)
            }
        }
    }

    /// A tap on a notification, or one of its buttons: the request it is about opens.
    public func notificationOpened(_ requestID: String, _ userInfo: [AnyHashable: Any]) async {
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("notification", "opened", ["request": requestID])
        await received(userInfo, pushDelivered: true)
        if requestID == firstRun.practiceID, practiceEnvelope(requestID) != nil { apply(.practiceTapped) }
    }

    func openNotice(_ userInfo: [AnyHashable: Any]) -> Agentkeyring_V2_SignedRequestEnvelope? {
        guard let keyID = state.deviceKeyID, let base64 = userInfo["akr"] as? String, let bytes = Data(base64Encoded: base64),
              let notice = try? Agentkeyring_V2_Notice(serializedBytes: bytes) else { return nil }
        do { return try keys.openNotice(notice, deviceKeyID: keyID) }
        catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("push", "notice did not open", ["error": "\(error)"]); return nil }
    }

    /// Requests whose notifications wait on the Lock Screen or in Notification Centre: the app sees a
    /// request's push only when it is in front or the notification is opened, so it reads them on coming to the front.
    /// Any notification that has already expired, settled, or collapsed to a passive outcome is removed on sight.
    func readDeliveredNotifications() async {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        let nowDate = Date()
        var staleIdentifiers: [String] = []
        for delivered in await center.deliveredNotifications() {
            let content = delivered.request.content
            let userInfo = content.userInfo
            if let endedID = PhoneNotification.ended(userInfo) {
                staleIdentifiers.append(delivered.request.identifier)
                staleIdentifiers.append(endedID)
                if let envelope = openNotice(userInfo) { receive(envelope, pushExpected: true) }
                continue
            }
            if let envelope = openNotice(userInfo) {
                receive(envelope, pushExpected: true)
                if let parsed = try? CredentialSealing.parseRequest(envelope.request),
                   CredentialRequestLifecycle.effectiveState(of: envelope, now: nowDate) != .waiting || settled(parsed.requestID) {
                    staleIdentifiers.append(delivered.request.identifier)
                    staleIdentifiers.append(parsed.requestID)
                }
            } else if let decoded = PhoneNotification.decode(userInfo) {
                if case let .waitingForYou(deadline) = decoded.state, deadline <= nowDate {
                    staleIdentifiers.append(delivered.request.identifier)
                    staleIdentifiers.append(decoded.id)
                } else if settled(decoded.id) {
                    staleIdentifiers.append(delivered.request.identifier)
                    staleIdentifiers.append(decoded.id)
                }
            }
        }
        if !staleIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(Set(staleIdentifiers)))
        }
        #endif
    }

    @discardableResult
    func receive(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, allowRefresh: Bool = true, pushExpected: Bool? = nil) -> Bool {
        guard let request = try? CredentialSealing.parseRequest(envelope.request), let members, let keyID = state.deviceKeyID else { return false }
        // Only a cryptographically verified request: either signed by the computer it names (returning Machine),
        // or a verified practice request for this device (returning nil without throwing).
        let verifiedMachine: Agentkeyring_V2_Machine?
        do {
            verifiedMachine = try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keyID)
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("request", "refused", ["request": request.requestID, "reason": "signature check failed"])
            if members.machines.contains(where: { $0.machineID == request.machineID }) == false {
                // Preserve monotonic outcome order so an older waiting or approved notice cannot resurrect a finished request.
                if let existing = unverifiedRequestEnvelopes[request.requestID] {
                    if existing.request == envelope.request,
                       (!existing.hasOutcome && envelope.hasOutcome)
                        || (existing.hasOutcome && envelope.hasOutcome && CredentialRequestLifecycle.canTransition(from: existing.outcome.state, to: envelope.outcome.state)) {
                        unverifiedRequestEnvelopes[request.requestID] = envelope
                    }
                } else {
                    unverifiedRequestEnvelopes[request.requestID] = envelope
                }
                if allowRefresh { Task { await refresh() } }
            }
            return false
        }
        let isVerifiedPractice = (verifiedMachine == nil)
        // A request is written once; a later notice may only advance its outcome monotonically.
        let saved = state.requestEnvelopes[request.requestID].flatMap { try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) }
        if let saved, saved.request != envelope.request { return false }
        if let saved, saved.hasOutcome {
            if !envelope.hasOutcome || !CredentialRequestLifecycle.canTransition(from: saved.outcome.state, to: envelope.outcome.state) { return true }
        }
        var next = state
        next.requestEnvelopes[request.requestID] = try? envelope.serializedData()
        if envelope.hasOutcome {
            next.answered[request.requestID] = nil
            watchDismissedIDs.remove(request.requestID)
            PhoneDeliveredNotifications.removeRequestNotification(request.requestID)
            onRequestDismissed?(request.requestID)
        }
        if isVerifiedPractice, request.requestID == firstRun.practiceID, envelope.hasOutcome {
            let reply = envelope.outcome.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            next.lastPracticeReply = reply.isEmpty ? nil : reply
        }
        Self.pruneExpiredEnvelopes(in: &next)
        save(next)
        guard isVerifiedPractice, request.requestID == firstRun.practiceID else {
            // A login this iPhone has not seen yet: the Mac's lists changed since it last looked.
            if !request.loginID.isEmpty, catalogue?.logins.contains(where: { $0.loginID == request.loginID }) != true { Task { await refresh() } }
            return true
        }
        if envelope.hasOutcome {
            apply(.practiceEnded(Self.outcome(envelope.outcome.state)))
        } else {
            apply(.practiceArrived(pushExpected: pushExpected ?? (facts.allowed && pushRegistered)))
        }
        return true
    }

    /// Tells the other devices and computers where to wake this iPhone, and the key its notices are sealed to.
    /// Signed with the reply key. If signing fails while the iPhone is locked, the token stays pending and
    /// finishes registering automatically once unlocked.
    public func registerPush(token: Data, topic: String, production: Bool) async throws {
        pushState = .pending(token: token, topic: topic, production: production)
        try await completePendingPushRegistration()
    }

    func completePendingPushRegistration() async throws {
        guard case let .pending(token, topic, production) = pushState else { return }
        var registration = Agentkeyring_V2_PushRegistration()
        registration.deviceKeyID = try CredentialSealing.keyID(keys.signingPublicKey())
        registration.apnsToken = token
        registration.apnsTopic = topic
        registration.apnsProduction = production
        registration.noticePublicKey = try keys.noticePublicKey()
        try await post(registration)
        guard case .pending(token, topic, production) = pushState else { return }
        pushState = .registered
        refreshPasswordsCopy()
        syncPractice()
    }

    /// Ensures this joined iPhone has a signed push registration: finishes a pending token once unlocked,
    /// or asks iOS for a token when none has arrived yet.
    func ensurePushRegistration() {
        guard state.deviceKeyID != nil else { return }
        switch pushState {
        case .registered:
            break
        case .pending:
            guard pushRegistering == nil else { return }
            pushRegistering = Task { [weak self] in
                defer { self?.pushRegistering = nil }
                do {
                    try await self?.completePendingPushRegistration()
                    if self?.pushRegistered == true {
                        KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Push address registered with the Mac"])
                    }
                } catch {
                    KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Could not register for pushes: \(error)"])
                }
            }
        case .none:
            onNeedPushAddress?()
        }
    }

    /// A push registration, this iPhone's or its Watch's, signed with this iPhone's reply key.
    func post(_ registration: Agentkeyring_V2_PushRegistration) async throws {
        var registration = registration
        registration.domain = "agentkeyring.push.v2"
        // Strictly after the one it replaces, so a second token in the same second still wins on every device.
        let previous = state.pushRegistrations[registration.deviceKeyID].flatMap { try? SignedDocument(serializedBytes: $0) }
            .flatMap { try? Agentkeyring_V2_PushRegistration(serializedBytes: $0.payload) }?.registeredUnixSeconds ?? 0
        registration.registeredUnixSeconds = max(Int64(Date().timeIntervalSince1970), previous + 1)
        let signed = try CredentialSealing.signedDocument(registration.serializedData(), by: CredentialSealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        // Kept to send with answers and in mailboxes, so a computer learns a new push address, and shared in iCloud.
        var next = state
        next.pushRegistrations[registration.deviceKeyID] = try signed.serializedData()
        save(next)
        cloudSync.pushCloudSoon()
    }

    /// Explicit lifecycle of this launch's APNs registration: missing, held pending unlock, or registered.
    enum PushRegistrationState: Equatable, Sendable {
        case none
        case pending(token: Data, topic: String, production: Bool)
        case registered
    }

    var pushRegistered: Bool { pushState == .registered }

    // MARK: Answers

    public func approveAccessRequest(_ requestID: String, reusingUnlock: Bool) async throws {
        // Check settlement FIRST for both real and practice requests so an already-answered request
        // never triggers a redundant Face ID prompt.
        if settled(requestID) { return PhoneDeliveredNotifications.removeRequestNotification(requestID) }
        if let envelope = practiceEnvelope(requestID) { return try await approvePractice(envelope, reusingUnlock: reusingUnlock) }
        let envelope = try loadRequestEnvelope(requestID)
        let request = try CredentialSealing.parseRequest(envelope.request)
        guard CredentialRequestLifecycle.isWaiting(envelope) else {
            PhoneDeliveredNotifications.removeRequestNotification(requestID)
            throw PhoneApprovalError.notAllowed("This request has already timed out.")
        }
        guard let members, let machine = try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: state.deviceKeyID ?? "") else {
            throw PhoneApprovalError.notAllowed("This iPhone may not approve this request.")
        }
        var copy = try ownCopy(for: request, members: members)
        if copy == nil, await refresh() { copy = try ownCopy(for: request, members: members) }
        guard let (login, _) = copy else {
            let deleted = catalogue?.logins.first { $0.loginID == request.loginID }.map { !$0.holdsSecret } == true
            throw PhoneApprovalError.notAllowed(deleted ? PhoneCopy.passwordDeletedWhenBlocked : PhoneCopy.passwordNotOnThisIPhone)
        }
        let context = LAContext()
        defer { context.invalidate() }
        if reusingUnlock { context.touchIDAuthenticationAllowableReuseDuration = 10 }
        try await keys.authorize(context, reason: PhoneCopy.faceIDApprove(agent: request.agent, computer: machine.label, site: Self.site(login)))
        // Re-check settlement, deadline, membership, and password copy after Face ID in case anything changed while authenticating.
        if settled(requestID) { return PhoneDeliveredNotifications.removeRequestNotification(requestID) }
        let freshEnvelope = try loadRequestEnvelope(requestID)
        guard CredentialRequestLifecycle.isWaiting(freshEnvelope) else {
            PhoneDeliveredNotifications.removeRequestNotification(requestID)
            throw PhoneApprovalError.notAllowed("This request has already timed out.")
        }
        guard freshEnvelope.request == envelope.request,
              let freshMembers = self.members,
              let freshMachine = try CredentialSealing.verifySignedLeaseRequest(freshEnvelope, members: freshMembers, ownKeyID: state.deviceKeyID ?? ""),
              let (freshLogin, freshSealed) = try ownCopy(for: request, members: freshMembers),
              // What Face ID approved: the same password, version and computer key as shown before it.
              freshLogin.version == login.version, freshLogin.title == login.title, freshLogin.sites == login.sites,
              freshLogin.account == login.account, freshMachine.receivingPublicKey == machine.receivingPublicKey else {
            throw PhoneApprovalError.notAllowed("This request is no longer allowed.")
        }
        let secret = try keys.openSealedLogin(freshSealed, context: context)
        try CredentialSealing.verifyOpenedLoginBinding(secret, title: freshLogin.title, sites: freshLogin.sites, account: freshLogin.account)
        let upload = try CredentialSealing.buildSignedApproval(
            request: freshEnvelope.request, secret: secret, sites: freshLogin.sites,
            receivingKey: P256.KeyAgreement.PublicKey(x963Representation: freshMachine.receivingPublicKey),
            signerKeyID: CredentialSealing.keyID(keys.signingPublicKey())) { try keys.signWithDeviceKey($0, context: context) }
        try await send(upload, for: freshEnvelope, approving: true)
        await sealMissingWatchCopies(context: context)
    }

    /// The password a request is for, from the signed Catalogue, and this iPhone's copy of it, checked
    /// against the Catalogue. Nil if this iPhone holds no current copy.
    func ownCopy(for request: KeyringRequest, members: Members) throws -> (Agentkeyring_V2_Login, SealedLogin)? {
        let login = try CredentialSealing.signedLogin(for: request, in: catalogue)
        guard let sealed = ownCopies[request.loginID], (try? CredentialSealing.verifySealedLogin(sealed, members: members, listed: login)) != nil else { return nil }
        return (login, sealed)
    }

    public func denyAccessRequest(_ requestID: String, reply: String?) async throws {
        // Check settlement and expiry FIRST for both real and practice requests.
        if settled(requestID) { return PhoneDeliveredNotifications.removeRequestNotification(requestID) }
        let envelope = try loadRequestEnvelope(requestID)
        guard CredentialRequestLifecycle.isWaiting(envelope) else {
            PhoneDeliveredNotifications.removeRequestNotification(requestID)
            return
        }
        guard let members, let keyID = state.deviceKeyID else {
            throw PhoneApprovalError.notAllowed("This iPhone has not joined yet.")
        }
        _ = try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keyID)
        let upload: AnswerUpload
        if let reply, !reply.isEmpty {
            upload = try CredentialSealing.buildSignedDenial(request: envelope.request, reply: reply, signerKeyID: CredentialSealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        } else {
            upload = CredentialSealing.buildUnsignedDenial(requestID: requestID)
        }
        if try await send(upload, for: envelope, approving: false) {
            settleOwnPractice(envelope, upload: upload)
        }
    }

    /// This iPhone is delivering an answer, the relay has an answer, or the request has ended.
    func settled(_ requestID: String) -> Bool {
        inFlightAnswers[requestID] != nil || state.answered[requestID] != nil
            || state.requestEnvelopes[requestID].flatMap { try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) }?.hasOutcome == true
    }

    /// The signed request envelope for a request, as its push brought it.
    func loadRequestEnvelope(_ requestID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        guard let saved = state.requestEnvelopes[requestID], let envelope = try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: saved) else {
            throw PhoneApprovalError.notAllowed("This request is no longer on this iPhone.")
        }
        return envelope
    }

    /// Puts an answer in the request's answer box, retrying while the relay cannot be reached. It is then
    /// sent, and shown as sending until the outcome's push. It carries this iPhone's signed lists, so that
    /// computer learns a Blocked password or a removed device from it. Returns true if this upload was accepted.
    @discardableResult
    func send(_ upload: AnswerUpload, for envelope: Agentkeyring_V2_SignedRequestEnvelope, approving: Bool) async throws -> Bool {
        let request = try CredentialSealing.parseRequest(envelope.request)
        let requestID = request.requestID
        guard !settled(requestID) else { return false }
        inFlightAnswers[requestID] = approving
        publish()
        defer {
            let removedInFlight = inFlightAnswers.removeValue(forKey: requestID) != nil
            let removedUndelivered = undelivered.remove(requestID) != nil
            if removedInFlight || removedUndelivered { publish() }
        }
        // Lean: the lists, a Freshness, and with an approval only that computer's own Automatic copies. While the
        // catalogue is contested or iCloud has not taken the lists, only Members and push addresses go: a catalogue,
        // a Freshness or a copy then could keep Automatic a password the merged list Blocks.
        var lists = lists(for: request.machineID, copies: approving ? .computerOnly : .none)
        if cloudSync.listsHeldFromComputers {
            lists.clearCatalogue()
            lists.copies = []
        } else if !request.machineID.isEmpty, let fresh = cloudSync.mailboxes.signedFreshness(for: request.machineID) { lists.freshness = fresh }
        let label = members?.devices.first { $0.keyID == state.deviceKeyID }?.label ?? "iPhone"
        let delivered: Bool
        do {
            _ = try await AnswerBox.answer(upload, for: request, by: label, bundle: lists) { [weak self] in
                Task { @MainActor in
                    guard let self, self.inFlightAnswers[requestID] != nil, self.undelivered.insert(requestID).inserted else { return }
                    self.publish()
                }
            }
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("answer", "delivered", ["request": requestID])
            delivered = true
        } catch is AnswerBox.AlreadyAnswered {
            // Another device answered first: the outcome's push says how it ended.
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("answer", "already answered", ["request": requestID])
            delivered = false
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("answer", "not delivered", ["request": requestID, "error": "\(error)"])
            throw error
        }
        // Persist our answer only when the relay actually accepted it (not on AlreadyAnswered, where
        // another device may have chosen the opposite outcome) and no outcome push settled it first.
        if delivered, let current = try? loadRequestEnvelope(requestID), !current.hasOutcome {
            var next = state
            next.answered[requestID] = approving
            save(next)
        }
        PhoneDeliveredNotifications.removeRequestNotification(requestID)
        onRequestDismissed?(requestID)
        return delivered
    }



    /// Ends an approval early by marking its grant at the relay: the asking computer's next use of the
    /// password fails. Throws `PhoneStopNotConfirmed` when the Stop was sent but not yet confirmed.
    public func endApprovedAccess(_ requestID: String) async throws {
        let envelope = try loadRequestEnvelope(requestID)
        let request = try CredentialSealing.parseRequest(envelope.request)
        guard let keyID = state.deviceKeyID else { throw PhoneApprovalError.notJoined }
        var end = Agentkeyring_V2_EndRequest()
        end.domain = "agentkeyring.end.v2"
        end.requestID = requestID
        end.deviceKeyID = keyID
        end.endedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signed = try CredentialSealing.signedDocument(end.serializedData(), by: CredentialSealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        // The request's grant is marked stopped, and that computer refuses every use after.
        guard try await AnswerBox.stopLeaseGrant(signed, for: request) else {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("stop", "sent, not confirmed", ["request": requestID])
            throw PhoneStopNotConfirmed()
        }
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("stop", "grant stopped", ["request": requestID])
        var ended = envelope
        ended.outcome = envelope.hasOutcome ? envelope.outcome : Agentkeyring_V2_Lease()
        ended.outcome.requestID = requestID
        ended.outcome.loginID = request.loginID
        ended.outcome.state = .ended
        ended.outcome.endedBy = members?.devices.first { $0.keyID == keyID }?.label ?? "iPhone"
        receive(ended)
    }

    // MARK: Requests as the screens show them

    /// Marks a request dismissed/answered on Apple Watch so in-app Waiting UI clears immediately.
    public func watchDismissedRequest(_ requestID: String) {
        guard !requestID.isEmpty else { return }
        if watchDismissedIDs.insert(requestID).inserted {
            publish()
        }
    }

    func accessRequest(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, _ members: Members, _ catalogue: Catalogue?) -> AccessRequest? {
        guard let request = try? CredentialSealing.parseRequest(envelope.request) else { return nil }
        if !envelope.hasOutcome && watchDismissedIDs.contains(request.requestID) { return nil }
        let nowDate = Date()
        let now = Int64(nowDate.timeIntervalSince1970)
        let effective = CredentialRequestLifecycle.effectiveState(of: envelope, now: nowDate)
        if isPracticeEnvelope(envelope) {
            var practice = Self.practiceRequest(request)
            if envelope.hasOutcome { practice.state = Self.state(envelope.outcome, now: now, members: members) }
            else if effective == .unanswered { practice.state = .unanswered }
            else if let approved = inFlightAnswers[request.requestID] ?? self.state.answered[request.requestID] { practice.state = .sendingAnswer(approved ? .approve : .deny) }
            return practice
        }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { return nil }
        let login = catalogue?.logins.first { $0.loginID == request.loginID }
        let state: AccessRequestState
        if envelope.hasOutcome {
            state = Self.state(envelope.outcome, now: now, members: members)
        } else if effective == .unanswered {
            state = .unanswered
        } else if let approved = inFlightAnswers[request.requestID] ?? self.state.answered[request.requestID] {
            state = .sendingAnswer(approved ? .approve : .deny)
        } else {
            state = .waitingForYou(until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
        }
        return AccessRequest(
            id: request.requestID,
            login: RequestedLogin(site: login.map(Self.site) ?? request.loginID, account: login?.account ?? ""),
            agent: RequestingAgent(name: request.agent.isEmpty ? PhoneCopy.anAgent : request.agent, machine: machine.label, address: "",
                                   project: request.project.isEmpty ? nil : request.project),
            access: .login,
            agentReason: request.reason, askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)), state: state)
    }

    nonisolated static func state(_ lease: Agentkeyring_V2_Lease, now: Int64, members: Members? = nil) -> AccessRequestState {
        PhoneNoticeDecoder.leaseState(lease, now: now, members: members)
    }

    nonisolated static func rule(_ login: Agentkeyring_V2_Login) -> LoginRule {
        LoginRule(storedRule: login.rule)
    }

    nonisolated static func site(_ login: Agentkeyring_V2_Login) -> String {
        PhoneNoticeDecoder.site(login)
    }

    /// "Approved on your Watch": the kind of device, as Paper names it.
    nonisolated static func shortName(_ kind: Agentkeyring_V2_DeviceKind) -> String? {
        PhoneNoticeDecoder.shortName(kind)
    }

    // MARK: For the notification service extension

    /// Whether a request arriving now may break through a Focus, from the iPhone's Settings.
    nonisolated public static func breaksThroughFocus(_ shared: PhoneSharedContext) -> Bool {
        PhoneNoticeDecoder.breaksThroughFocus(shared)
    }

    /// The request a push is about, as the Lock Screen shows it: the notice opened, the login and computer
    /// named from the saved Catalogue and Members.
    nonisolated public static func notifiedRequest(_ userInfo: [AnyHashable: Any], shared: PhoneSharedContext,
                                                   open: (Agentkeyring_V2_Notice, String) throws -> Agentkeyring_V2_SignedRequestEnvelope) -> DecodedPushNotificationRequest? {
        PhoneNoticeDecoder.notifiedRequest(userInfo, shared: shared, open: open)
    }

    /// An opened notice's request, named from the signed Members and Catalogue only: this iPhone's own
    /// practice request, or one the computer it names signed.
    nonisolated static func named(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, members: Members, catalogue: Catalogue?, keyID: String) throws -> (request: AccessRequest, answeredBy: String?) {
        try PhoneNoticeDecoder.named(envelope, members: members, catalogue: catalogue, keyID: keyID)
    }

    // MARK: Requests that ended

    private static let settledEnvelopeRetentionSeconds: Int64 = 86_400

    static func pruneExpiredEnvelopes(in state: inout PhoneSavedState, now: Date = .now) {
        let cutoff = Int64(now.timeIntervalSince1970) - settledEnvelopeRetentionSeconds
        let before = state.requestEnvelopes.count
        state.requestEnvelopes = state.requestEnvelopes.filter { _, bytes in
            guard let envelope = try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: bytes),
                  let parsed = try? CredentialSealing.parseRequest(envelope.request) else { return false }
            let settled = CredentialRequestLifecycle.effectiveState(of: envelope, now: now) != .waiting
            guard settled else { return true }
            let latestTimestamp = max(parsed.askedUnixSeconds, parsed.answerByUnixSeconds, envelope.outcome.notAfterUnixSeconds)
            return latestTimestamp > cutoff
        }
        if state.requestEnvelopes.count != before {
            state.answered = state.answered.filter { state.requestEnvelopes[$0.key] != nil }
        }
    }

    func pruneExpiredEnvelopes() {
        var next = state
        let beforeEnvelopes = next.requestEnvelopes
        let beforeAnswered = next.answered
        Self.pruneExpiredEnvelopes(in: &next)
        if next.requestEnvelopes != beforeEnvelopes || next.answered != beforeAnswered {
            save(next)
        }
    }

    func scheduleRequestExpiryTimer() {
        requestExpiryTimer?.cancel()
        requestExpiryTimer = nil
        let nowDate = Date()
        let now = Int64(nowDate.timeIntervalSince1970)
        var earliest: Int64?
        for bytes in state.requestEnvelopes.values {
            guard let envelope = try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: bytes),
                  CredentialRequestLifecycle.isWaiting(envelope, now: nowDate),
                  let parsed = try? CredentialSealing.parseRequest(envelope.request),
                  !watchDismissedIDs.contains(parsed.requestID),
                  parsed.answerByUnixSeconds > now else { continue }
            earliest = earliest.map { min($0, parsed.answerByUnixSeconds) } ?? parsed.answerByUnixSeconds
        }
        guard let earliest else { return }
        let delay = max(0.5, TimeInterval(earliest - now) + 0.5)
        requestExpiryTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.publish()
            self.scheduleRequestExpiryTimer()
        }
    }
}
