// Written by AI on 2026.11.21 by model claude opus 5.5; through pushes and answer boxes only, with the
// doors cut, on 2026.11.24.
//
// Requests from agents on Josh's other computers, shown in this Mac's panel
// (docs/state-machines.md, "Another computer's request on the Mac").
//
// The asking computer owns its request: it pushes it to this Mac, the iPhone
// and Apple Watch, and takes the first answer from its answer box. This Mac
// answers there exactly as a device does: Touch ID opens its own copy, which
// it seals again to that computer's receiving key. A denial is signed with
// this Mac's reply key. The hold after a denial is the asking computer's;
// nothing here holds anything off. An approval stays here for its 30
// minutes, so Stop here can end it at any time in them.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

public enum RemoteComputerRequestState: Equatable, Sendable {
    /// Shown in the panel; nobody has answered.
    case waiting
    /// Answered here or elsewhere, stopped asking, or out of time: the request as it ended.
    case ended(Agentkeyring_V2_Lease)
}

/// One request from another computer, as the panel shows it.
public struct RemoteComputerRequest: Sendable {

    /// The Request bytes and the asking computer's signature over them.
    public let signed: Agentkeyring_V2_Signed
    public let request: Agentkeyring_V2_Request
    public let computer: Agentkeyring_V2_Machine
    /// The password, from the signed catalogue.
    public let login: Agentkeyring_V2_Login
    public internal(set) var state = RemoteComputerRequestState.waiting

    public var id: String { request.requestID }
}

@MainActor
extension MacSyncCoordinator {

    /// How long an ended request stays, so the panel can show how it ended before it closes.
    static let endedKeptFor: TimeInterval = 60

    /// How long a request that ended this way stays here: an approval until its time runs out, so it can be
    /// stopped here until then; anything else a minute.
    static func keptFor(_ lease: Agentkeyring_V2_Lease, now: Date) -> TimeInterval {
        guard CredentialRequestLifecycle.effectiveState(of: lease, now: now) == .approved else { return endedKeptFor }
        return max(endedKeptFor, TimeInterval(lease.notAfterUnixSeconds) - now.timeIntervalSince1970)
    }

    /// Other computers' requests waiting for Josh, oldest first.
    public var waitingRemoteAsks: [RemoteComputerRequest] {
        let nowUnix = Int64(Date.now.timeIntervalSince1970)
        return remoteAsks.values.filter {
            $0.state == .waiting && $0.request.answerByUnixSeconds > nowUnix
        }.sorted { $0.request.askedUnixSeconds < $1.request.askedUnixSeconds }
    }

    // MARK: Shown and ended

    /// A request another computer signed and pushed to this Mac, beside the devices, checked as a device
    /// checks one (`CredentialSealing.verifySignedLeaseRequest`) and shown in the panel.
    @discardableResult
    func takeRemoteAsk(_ envelope: Agentkeyring_V2_SignedRequestEnvelope) -> PeerIntakeOutcome {
        guard let members, let request = try? CredentialSealing.parseRequest(envelope.request) else {
            return .refused("The push holds no request.")
        }
        guard let computer = (try? CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keys.deviceKeyID)) ?? nil else {
            return .refused("A request is signed by the computer it names, in the user's list of devices.")
        }
        guard request.forDeviceKeyID.isEmpty, !request.automatic else {
            return .refused("Only a request that waits for the user is shown on the Mac.")
        }
        // A push can arrive late: a request already out of time is not shown.
        guard request.answerByUnixSeconds > Int64(Date.now.timeIntervalSince1970) else { return .refused("This request has already timed out.") }
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }), login.rule != .blocked else {
            return .refused("This Mac's list has no such password, or it is blocked.")
        }
        guard login.holdsSecret, secretDeletedHere?(request.loginID) != true else { return .refused(MessageCopy.secretDeletedForAgent) }
        guard remoteAsks[request.requestID] == nil else { return .taken } // Shown already.
        var signed = Agentkeyring_V2_Signed()
        signed.payload = envelope.request
        signed.signature = envelope.requestSignature
        signed.signerKeyID = computer.machineID
        remoteAsks[request.requestID] = RemoteComputerRequest(signed: signed, request: request, computer: computer, login: login)
        KeyringDiagnosticLog.mac.noteDeviceEvent("remote", "shown", ["request": request.requestID, "computer": computer.label, "login": request.loginID])
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
        return .taken
    }

    /// How the request ended, once: the first outcome wins, whoever tells it, except that an approval may
    /// still end early (released, stopped, out of time). The record goes `keptFor` later, unless it ended
    /// again meanwhile.
    func endRemote(_ id: String, _ lease: Agentkeyring_V2_Lease) {
        guard let current = remoteAsks[id]?.state else { return }
        let nextState = CredentialRequestLifecycle.effectiveState(of: lease, now: .now)
        let previousState: Agentkeyring_V2_LeaseState = switch current {
        case .waiting: .waiting
        case let .ended(previous): CredentialRequestLifecycle.effectiveState(of: previous, now: .now)
        }
        guard CredentialRequestLifecycle.canTransition(from: previousState, to: nextState) else { return }
        var normalizedLease = lease
        normalizedLease.state = nextState
        let ended = RemoteComputerRequestState.ended(normalizedLease)
        remoteAsks[id]?.state = ended
        KeyringDiagnosticLog.mac.noteDeviceEvent("remote", "ended", ["request": id, "state": "\(nextState)", "by": normalizedLease.answeredBy])
        let keptFor = Self.keptFor(normalizedLease, now: .now)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(keptFor))
            if self?.remoteAsks[id]?.state == ended { self?.remoteAsks[id] = nil }
        }
    }

    // MARK: Answering in the asking computer's answer box

    /// Josh approves another computer's request: after Touch ID this Mac opens
    /// its own copy, seals it to that computer's receiving key for 30 minutes,
    /// and puts it in the request's answer box. Returns the request as this Mac
    /// knows it: sent, with the outcome to come by push, or the one that ended it first.
    public func approveRemote(_ id: String, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws -> Agentkeyring_V2_Lease {
        guard let ask = remoteAsks[id] else { throw AgentRPCError(.notFound, MessageCopy.somethingWentWrong) }
        if case let .ended(lease) = ask.state { return lease }
        guard let copy = try await store.sealed().first(where: {
            $0.openerID == keys.deviceKeyID && $0.loginID == ask.login.loginID && $0.version == ask.login.version
        }) else { throw AgentRPCError(.notFound, MessageCopy.noCopyOnThisMac) }
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
            throw AgentRPCError(.notFound, MessageCopy.somethingWentWrong)
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
            throw AgentRPCError(.permissionDenied, MessageCopy.somethingWentWrong)
        }
        guard let freshCopy = sealedCopies.first(where: {
            $0.openerID == keys.deviceKeyID && $0.loginID == shownLoginID && $0.version == shownVersion
        }) else { throw AgentRPCError(.notFound, MessageCopy.noCopyOnThisMac) }
        try keys.check(freshCopy, members: freshMembers, listed: freshLogin)
        let secret = try keys.openSealedLogin(freshCopy, context: context)
        try CredentialSealing.verifyOpenedLoginBinding(secret, title: shownTitle, sites: shownSites, account: shownAccount)
        onAuthenticated()
        let upload = try CredentialSealing.buildSignedApproval(request: liveAsk.signed.payload, secret: secret, sites: shownSites, receivingKey: receiving,
            signerKeyID: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: context) }
        return try await answerRemote(liveAsk, upload)
    }

    /// Josh denies another computer's request, with his words or none, signed
    /// with this Mac's reply key so the agent sees they are his. The asking computer holds the password off.
    public func denyRemote(_ id: String, reply: String) async throws -> Agentkeyring_V2_Lease {
        guard let ask = remoteAsks[id] else { throw AgentRPCError(.notFound, MessageCopy.somethingWentWrong) }
        if case let .ended(lease) = ask.state { return lease }
        let upload = try CredentialSealing.buildSignedDenial(request: ask.signed.payload, reply: reply, signerKeyID: keys.replyKeyID, sign: keys.signReply)
        return try await answerRemote(ask, upload)
    }

    private func answerRemote(_ ask: RemoteComputerRequest, _ upload: Agentkeyring_V2_AnswerUpload) async throws -> Agentkeyring_V2_Lease {
        let bundle = await answerLists(for: ask.computer.machineID, includeCopies: upload.hasDelivery)
        let lease: Agentkeyring_V2_Lease
        do { lease = try await AnswerBox.answer(upload, for: ask.request, by: keys.label, bundle: bundle) } catch is AnswerBox.AlreadyAnswered {
            throw AgentRPCError(.permissionDenied, MessageCopy.answeredElsewhere(ask.computer.label))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("remote", "answer-not-delivered", ["request": ask.id, "reason": "\(error)"])
            throw AgentRPCError(.unavailable, MessageCopy.answerNotDelivered(ask.computer.label))
        }
        KeyringDiagnosticLog.mac.noteDeviceEvent("remote", "answered", ["request": ask.id, "state": "\(lease.state)", "by": lease.answeredBy])
        endRemote(ask.id, lease)
        if case let .ended(shown)? = remoteAsks[ask.id]?.state { return shown }
        return lease
    }

    /// Stop on this Mac for another computer's approval: its grant is marked stopped, with this Mac's signed
    /// EndRequest, and that computer refuses every use after.
    public func stopRemote(_ id: String) async throws -> Agentkeyring_V2_Lease {
        guard let ask = remoteAsks[id], let relay = RelayBoxClient(for: ask.request) else {
            throw AgentRPCError(.notFound, MessageCopy.endsByItself)
        }
        var end = Agentkeyring_V2_EndRequest()
        end.domain = "agentkeyring.end.v2"
        end.requestID = id
        end.deviceKeyID = keys.deviceKeyID
        end.endedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signed = try CredentialSealing.signedDocument(end.serializedData(), by: keys.replyKeyID, sign: keys.signReply)
        let stopped: Bool
        do {
            stopped = try await relay.stopLeaseGrantBox(answerBox: ask.request.answerBoxID, key: ask.request.answerBoxKey, requestID: id,
                                           signedEnd: signed.serializedData())
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("remote", "stop-not-sent", ["request": id, "reason": "\(error)"])
            throw AgentRPCError(.unavailable, MessageCopy.answerNotDelivered(ask.computer.label))
        }
        var lease = Agentkeyring_V2_Lease()
        if case let .ended(shown) = ask.state { lease = shown }
        lease.requestID = id
        lease.loginID = ask.request.loginID
        lease.state = .ended
        lease.endedBy = keys.label
        guard stopped else { throw AgentRPCError(.unavailable, MessageCopy.answerNotDelivered(ask.computer.label)) }
        KeyringDiagnosticLog.mac.noteDeviceEvent("remote", "stopped", ["request": id])
        endRemote(id, lease)
        return remoteAsks[id].flatMap { if case let .ended(shown) = $0.state { shown } else { nil } } ?? lease
    }

    /// This Mac's signed lists, sent with an answer, with a Freshness for that computer: an approved Ask
    /// brings a computer's lists up to date, including its current Automatic copies. While the catalogue is
    /// contested or iCloud has not taken the lists, only Members and push addresses go: a catalogue, a
    /// Freshness or a copy then could keep Automatic a password the merged list Blocks.
    private func answerLists(for machineID: String, includeCopies: Bool) async -> Agentkeyring_V2_Bundle {
        var lists = Agentkeyring_V2_Bundle()
        if let bytes = saved.members, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) { lists.members = signed }
        lists.membersSince = saved.membersHistory.compactMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }
        lists.pushRegistrations = saved.pushRegistrations.keys.sorted().compactMap { saved.pushRegistrations[$0].flatMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) } }
        guard !cloudSync.listsHeldFromComputers else { return lists }
        if let fresh = cloudSync.mailboxes.signedFreshness(for: machineID) { lists.freshness = fresh }
        if let bytes = saved.catalogue, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) { lists.catalogue = signed }
        if includeCopies, let catalogue, members != nil {
            let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
            lists.copies = ((try? await store.sealed()) ?? []).filter { copy in
                guard let login = listed[copy.loginID], login.holdsSecret, login.version == copy.version else { return false }
                return copy.openerID == machineID && login.rule == .automatic
            }
        }
        return lists
    }
}
#endif
