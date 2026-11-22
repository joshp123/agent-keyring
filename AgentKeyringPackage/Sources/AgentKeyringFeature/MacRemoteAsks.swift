// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Requests from agents on Josh's other computers, shown in this Mac's panel,
// and Stops a device could not take to the asking computer's door
// (keyring.proto, "Direct: no relay": POST /v2/ask, /v2/outcome, /v2/stop,
// GET /v2/stops; docs/state-machines.md, "Another computer's request on the
// Mac" and "A Stop left at the Mac").
//
// The asking computer owns its request: it pushes it to the iPhone and Apple
// Watch, shows it here as it does, and takes the first answer at its own door.
// This Mac answers there exactly as a device does: Touch ID opens its own
// copy, which it seals again to that computer's receiving key. A denial is
// signed with this Mac's reply key. The hold after a denial is the asking
// computer's; nothing here holds anything off.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
extension MacDevice {
    /// One request from another computer, as the panel shows it.
    public struct RemoteAsk: Sendable {
        public enum State: Equatable, Sendable {
            /// Shown in the panel; nobody has answered.
            case waiting
            /// Answered here or elsewhere, stopped asking, or out of time: the request as it ended.
            case ended(Agentkeyring_V2_Lease)
        }

        /// The Request bytes and the asking computer's signature over them.
        public let signed: Agentkeyring_V2_Signed
        public let request: Agentkeyring_V2_Request
        public let computer: Agentkeyring_V2_Machine
        /// The password, from the signed catalogue.
        public let login: Agentkeyring_V2_Login
        public internal(set) var state = State.waiting

        public var id: String { request.requestID }
    }

    /// A Stop a device left here, kept an hour.
    struct KeptStop {
        let signed: Data
        let at: Date
    }

    static let stopKeptFor: TimeInterval = 3600
    /// How long an ended request stays, so the panel can show how it ended before it closes.
    static let endedKeptFor: Duration = .seconds(60)

    /// Other computers' requests waiting for Josh, oldest first.
    public var waitingRemoteAsks: [RemoteAsk] {
        remoteAsks.values.filter { $0.state == .waiting }.sorted { $0.request.askedUnixSeconds < $1.request.askedUnixSeconds }
    }

    // MARK: Shown and ended

    /// POST /v2/ask: a computer shows this Mac a request it signed and is pushing to the devices.
    func takeRemoteAsk(_ body: Data, from caller: Caller) -> DoorReply {
        guard case let .machine(computer) = caller else { return .refused(403, "Only a computer shows the Mac its own request.") }
        guard let members, let signed = try? Agentkeyring_V2_Signed(serializedBytes: body),
            let request = try? Sealing.parseRequest(signed.payload) else {
            return .refused(400, "The body must be a signed Request.")
        }
        var work = Agentkeyring_V2_Work()
        work.request = signed.payload
        work.requestSignature = signed.signature
        guard let asking = try? Sealing.checkRequest(work, members: members, ownKeyID: keys.deviceKeyID),
            asking.machineID == computer.machineID, signed.signerKeyID == computer.machineID else {
            return .refused(403, "A computer shows the Mac only a request it signed itself, naming its own door.")
        }
        guard request.forDeviceKeyID.isEmpty, !request.automatic else {
            return .refused(400, "Only a request that waits for Josh is shown on the Mac.")
        }
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }), login.rule != .blocked else {
            return .refused(403, "This Mac's list has no such password, or it is blocked.")
        }
        guard remoteAsks[request.requestID] == nil else { return .ok() } // Shown already.
        remoteAsks[request.requestID] = RemoteAsk(signed: signed, request: request, computer: computer, login: login)
        DiagnosticLog.record("remote", "shown", ["request": request.requestID, "computer": computer.label, "login": request.loginID])
        let id = request.requestID
        let answerBy = Date(timeIntervalSince1970: TimeInterval(request.answerByUnixSeconds))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, answerBy.timeIntervalSinceNow)))
            var lease = Agentkeyring_V2_Lease()
            lease.requestID = id
            lease.loginID = request.loginID
            lease.state = .unanswered
            lease.answerByUnixSeconds = request.answerByUnixSeconds
            self?.endRemote(id, lease)
        }
        return .ok()
    }

    /// POST /v2/outcome: the asking computer says how its request ended; the panel shows it and closes.
    func takeRemoteOutcome(_ body: Data, from caller: Caller) -> DoorReply {
        guard case let .machine(computer) = caller else { return .refused(403, "Only the computer that asked says how its request ended.") }
        guard let lease = try? Agentkeyring_V2_Lease(serializedBytes: body), !lease.requestID.isEmpty else {
            return .refused(400, "The body must be a Lease.")
        }
        guard let ask = remoteAsks[lease.requestID] else { return .ok() } // Not shown here, or gone.
        guard ask.computer.machineID == computer.machineID else { return .refused(403, "Only the computer that asked says how its request ended.") }
        endRemote(lease.requestID, lease)
        return .ok()
    }

    /// waiting to ended, once: the first outcome wins, whoever tells it. The record goes a minute later.
    func endRemote(_ id: String, _ lease: Agentkeyring_V2_Lease) {
        guard remoteAsks[id]?.state == .waiting, lease.state != .waiting else { return }
        remoteAsks[id]?.state = .ended(lease)
        DiagnosticLog.record("remote", "ended", ["request": id, "state": "\(lease.state)", "by": lease.answeredBy])
        Task { [weak self] in
            try? await Task.sleep(for: Self.endedKeptFor)
            if case .ended? = self?.remoteAsks[id]?.state { self?.remoteAsks[id] = nil }
        }
    }

    // MARK: Answering at the asking computer's door

    /// Josh approves another computer's request: after Touch ID this Mac opens
    /// its own copy, seals it to that computer's receiving key for 30 minutes,
    /// and posts it to the request's door. Returns the request as the door
    /// tells it: this answer's, or the one that ended it first.
    public func approveRemote(_ id: String, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws -> Agentkeyring_V2_Lease {
        guard let ask = remoteAsks[id] else { throw RelayFailure(.notFound, MessageCopy.somethingWentWrong) }
        if case let .ended(lease) = ask.state { return lease }
        guard let copy = try await store.sealed().first(where: {
            $0.openerID == keys.deviceKeyID && $0.loginID == ask.login.loginID && $0.version == ask.login.version
        }) else { throw RelayFailure(.notFound, MessageCopy.noCopyOnThisMac) }
        try keys.check(copy, members: members, listed: ask.login)
        let receiving = try P256.KeyAgreement.PublicKey(x963Representation: ask.computer.receivingPublicKey)
        let shownSignedRequest = ask.signed
        let shownLoginID = ask.login.loginID
        let shownVersion = ask.login.version
        let shownTitle = ask.login.title
        let shownSites = ask.login.sites
        let shownAccount = ask.login.account
        let shownMachineID = ask.computer.machineID
        let shownReceivingKey = ask.computer.receivingPublicKey
        try await confirm(context, reason: MessageCopy.useYourPassword(site: shownSites.first ?? shownTitle,
            account: shownAccount, agent: ask.request.agent, computer: ask.computer.label),
            until: Date(timeIntervalSince1970: TimeInterval(ask.request.answerByUnixSeconds)))
        // Fetch sealed copies BEFORE the final synchronous check so no await can interleave
        // between verifying live request/membership/login/version/key and opening the secret.
        let sealedCopies = try await store.sealed()
        guard let liveAsk = remoteAsks[id], liveAsk.signed == shownSignedRequest else {
            throw RelayFailure(.notFound, MessageCopy.somethingWentWrong)
        }
        if case let .ended(lease) = liveAsk.state { return lease }
        guard Date(timeIntervalSince1970: TimeInterval(liveAsk.request.answerByUnixSeconds)) > .now else {
            var expired = Agentkeyring_V2_Lease()
            expired.requestID = id
            expired.loginID = liveAsk.request.loginID
            expired.state = .unanswered
            expired.answerByUnixSeconds = liveAsk.request.answerByUnixSeconds
            endRemote(id, expired)
            return expired
        }
        guard let freshMembers = members,
              let freshMachine = freshMembers.machines.first(where: { $0.machineID == shownMachineID }),
              freshMachine.receivingPublicKey == shownReceivingKey,
              let freshLogin = catalogue?.logins.first(where: { $0.loginID == shownLoginID }),
              freshLogin.rule != .blocked,
              freshLogin.version == shownVersion,
              freshLogin.title == shownTitle, freshLogin.sites == shownSites, freshLogin.account == shownAccount else {
            throw RelayFailure(.permissionDenied, MessageCopy.somethingWentWrong)
        }
        guard let freshCopy = sealedCopies.first(where: {
            $0.openerID == keys.deviceKeyID && $0.loginID == shownLoginID && $0.version == shownVersion
        }) else { throw RelayFailure(.notFound, MessageCopy.noCopyOnThisMac) }
        try keys.check(freshCopy, members: freshMembers, listed: freshLogin)
        let secret = try keys.open(freshCopy, context: context)
        try Sealing.checkBound(secret, title: shownTitle, sites: shownSites, account: shownAccount)
        onAuthenticated()
        let upload = try Sealing.approve(request: liveAsk.signed.payload, secret: secret, sites: shownSites, receivingKey: receiving,
            signerKeyID: keys.deviceKeyID) { try keys.sign($0, context: context) }
        return try await answerRemote(liveAsk, upload)
    }

    /// Josh denies another computer's request, with his words or none, signed
    /// with this Mac's reply key so the agent sees they are his. The asking computer holds the password off.
    public func denyRemote(_ id: String, reply: String) async throws -> Agentkeyring_V2_Lease {
        guard let ask = remoteAsks[id] else { throw RelayFailure(.notFound, MessageCopy.somethingWentWrong) }
        if case let .ended(lease) = ask.state { return lease }
        let upload = try Sealing.deny(request: ask.signed.payload, reply: reply, signerKeyID: keys.replyKeyID, sign: keys.signReply)
        return try await answerRemote(ask, upload)
    }

    private func answerRemote(_ ask: RemoteAsk, _ upload: Agentkeyring_V2_AnswerUpload) async throws -> Agentkeyring_V2_Lease {
        guard let door = Sealing.answerDoor(ask.request) else { throw RelayFailure(.unavailable, MessageCopy.answerNotDelivered(ask.computer.label)) }
        let lease: Agentkeyring_V2_Lease
        do { lease = try await AnswerDoor.answer(upload, at: door) } catch let refused as AnswerDoor.Refused {
            DiagnosticLog.record("remote", "answer-refused", ["request": ask.id, "reason": refused.words])
            throw RelayFailure(.permissionDenied, MessageCopy.answerRefused(ask.computer.label, refused.words))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticLog.record("remote", "answer-not-delivered", ["request": ask.id, "reason": "\(error)"])
            throw RelayFailure(.unavailable, MessageCopy.answerNotDelivered(ask.computer.label))
        }
        DiagnosticLog.record("remote", "answered", ["request": ask.id, "state": "\(lease.state)", "by": lease.answeredBy])
        endRemote(ask.id, lease)
        if case let .ended(shown)? = remoteAsks[ask.id]?.state { return shown }
        return lease
    }

    // MARK: Stops left here

    /// POST /v2/stop: a device's Stop that could not reach the asking
    /// computer's door, kept an hour for that computer to ask for. Signed by
    /// the reply key of a device in the members list; the iPhone may carry its
    /// Apple Watch's. A Stop for one of this Mac's own requests ends it here at once.
    func takeStop(_ body: Data) -> DoorReply {
        guard let (document, signer) = fromDevice(body), document.signerKeyID == signer.replyKeyID,
            let end = try? Agentkeyring_V2_EndRequest(serializedBytes: document.payload),
            end.domain == "agentkeyring.end.v2", end.deviceKeyID == signer.keyID, !end.requestID.isEmpty else {
            return .refused(403, "Stop is signed by the reply key of a device in Josh's list of devices.")
        }
        pruneStops()
        stops[end.requestID] = KeptStop(signed: body, at: environment.now())
        DiagnosticLog.record("stop", "kept", ["request": end.requestID, "device": signer.label])
        if asks[end.requestID] != nil { _ = takeEnd(body) }
        return .ok()
    }

    /// GET /v2/stops?request=ID: the Stop left for that request, or 404. Asked
    /// by a computer before every use of an approval. Any computer may ask: an
    /// Automatic use never came here as a request, and the id is the request's
    /// own 128 random bits.
    func stop(for requestID: String, from caller: Caller) -> DoorReply {
        guard case .machine = caller else { return .refused(403, "Only a computer asks for a Stop left for its request.") }
        pruneStops()
        guard let kept = stops[requestID] else { return .refused(404, "No Stop is waiting for that request.") }
        DiagnosticLog.record("stop", "given", ["request": requestID])
        return .ok(kept.signed)
    }

    private func pruneStops() {
        let now = environment.now()
        stops = stops.filter { now.timeIntervalSince($0.value.at) < Self.stopKeptFor }
    }
}
