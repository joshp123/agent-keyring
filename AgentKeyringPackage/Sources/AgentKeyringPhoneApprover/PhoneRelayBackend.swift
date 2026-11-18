// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone as an approving device of protocol version 2. It keeps the
// signed Members and Catalogue, follows the relay's work stream, and answers:
// Approve opens the one sealed login after Face ID and seals it again for the
// asking machine; Deny with words is signed with the reply key; plain Deny
// is unsigned and grants nothing.

import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security

typealias Work = Agentkeyring_V2_Work
typealias Lease = Agentkeyring_V2_Lease

struct PhoneSavedState: Codable {
    var endpoint: RelayEndpoint?
    var members: Data?
    var catalogue: Data?
    /// request id → serialized Work, the latest the relay sent.
    var work: [String: Data] = [:]
    /// request id → what this iPhone answered, until the relay's outcome arrives.
    var answered: [String: Bool] = [:]
    /// This iPhone's Device.key_id, once joined; the extension needs it to open a notice.
    var deviceKeyID: String?
    var notificationsAsked = false
    var notificationsAllowed = false
    /// A push reached this iPhone since it joined.
    var pushSeen = false
    /// He approved first run's test request with Face ID.
    var testApproved = false
    /// What the Watch found when it tested itself, as its app sent it (a property list).
    var watchSelfTest: Data?
    /// Why joining stopped, in one plain line, if it did.
    var joinProblem: String?
    /// The Watch's Device and PushRegistration, serialized, as its app sent them, until it is added or refused.
    var watchDevice: Data?
    var watchPush: Data?
}

/// What the notification service extension needs to name a request: this
/// iPhone's key id, the Members and the Catalogue. Kept in the keychain group
/// the app shares with the extension, readable once the phone has been unlocked
/// after starting up.
public struct PhoneSharedContext {
    let service = "com.joshpalmer.AgentKeyring.Phone.shared-context"
    let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "context", kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func write(_ state: PhoneSavedState) {
        var shared = PhoneSavedState()
        shared.deviceKeyID = state.deviceKeyID; shared.members = state.members; shared.catalogue = state.catalogue
        guard let data = try? PropertyListEncoder().encode(shared) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func read() -> PhoneSavedState? {
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? PropertyListDecoder().decode(PhoneSavedState.self, from: data)
    }
}

@MainActor
public final class PhoneRelayBackend: PhoneBackend {
    private let directory: URL
    private let shared: PhoneSharedContext
    private let keys: any PhoneDeviceKeys
    private let identity: @MainActor () throws -> RelayTLSIdentity
    private var state = PhoneSavedState()
    private var following: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<PhoneSnapshot>.Continuation] = [:]
    private let logger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Relay")

    public init(directory: URL, shared: PhoneSharedContext, keys: any PhoneDeviceKeys,
                identity: @escaping @MainActor () throws -> RelayTLSIdentity) {
        self.directory = directory
        self.shared = shared
        self.keys = keys
        self.identity = identity
        if let data = try? Data(contentsOf: stateURL), let saved = try? PropertyListDecoder().decode(PhoneSavedState.self, from: data) {
            state = saved
        }
    }

    // MARK: What the screens see

    public func updates() -> AsyncStream<PhoneSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers.removeValue(forKey: id) } }
        }
    }

    public var snapshot: PhoneSnapshot {
        guard let members, state.deviceKeyID != nil else {
            let joining = PhoneSetupLine(id: "join", mark: state.joinProblem == nil ? .working : .failed,
                                         title: state.joinProblem == nil ? PhoneCopy.approveOnMac : (state.joinProblem ?? ""),
                                         detail: state.joinProblem == nil ? PhoneCopy.approveOnMacDetail : nil)
            return PhoneSnapshot(setup: PhoneSetup(lines: [joining], isReady: false))
        }
        let catalogue = self.catalogue
        let requests = state.work.values.compactMap { try? Work(serializedBytes: $0) }.compactMap { accessRequest($0, members, catalogue) }
        let logins = (catalogue?.logins ?? []).map { login in
            PhoneLogin(id: login.loginID, site: Self.site(login), account: login.account,
                       rule: login.rule == .automatic ? .automatic : login.rule == .blocked ? .blocked
                           : (login.phoneAndWatchOnly ? .askOnIPhoneOrWatch : .ask))
        }
        let mine = state.deviceKeyID
        let devices = members.devices.map { device in
            PhoneDevice(id: device.keyID, name: device.label, detail: Self.howItApproves(device.kind), role: .approves,
                        isThisIPhone: device.keyID == mine)
        } + members.machines.map { PhoneDevice(id: $0.machineID, name: $0.label, role: .asks) }
        let pendingWatch = state.watchDevice.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
        var snapshot = PhoneSnapshot(setup: setup(members: members, pendingWatch: pendingWatch), requests: requests,
                                     logins: logins, devices: devices)
        snapshot.joined = true
        snapshot.asksAboutNotifications = !state.notificationsAsked
        snapshot.testRequest = state.testApproved ? nil : testWork.flatMap { try? Sealing.parseRequest($0.request).requestID }
        snapshot.deviceRequest = pendingWatch.map { PhoneDeviceRequest(id: $0.keyID, name: $0.label, detail: PhoneCopy.pairedWithThisIPhone) }
        return snapshot
    }

    /// First run's list, worked out from what this iPhone knows.
    private func setup(members: Members, pendingWatch: Agentkeyring_V2_Device?) -> PhoneSetup {
        typealias L = PhoneSetupLine
        var lines = [L(id: "join", mark: .done, title: PhoneCopy.macAdded)]
        if !state.notificationsAsked {
            lines.append(L(id: "notifications", mark: .working, title: PhoneCopy.notificationsOn))
        } else if !state.notificationsAllowed {
            lines.append(L(id: "notifications", mark: .failed, title: PhoneCopy.notificationsOff,
                           detail: PhoneCopy.notificationsOffDetail, opensSettings: true))
        } else {
            lines.append(L(id: "notifications", mark: .done, title: PhoneCopy.notificationsOn))
        }
        let reachable = connectionFailed == nil
        lines.append(L(id: "reach", mark: !reachable ? .failed : (state.pushSeen ? .done : (state.notificationsAllowed ? .working : .notYet)),
                       title: reachable ? PhoneCopy.requestsReach : PhoneCopy.cantReachRelay))
        lines.append(L(id: "test", mark: state.testApproved ? .done : (state.notificationsAllowed ? .working : .notYet), title: PhoneCopy.testApproved))
        let watches = members.devices.filter { $0.kind == .watch }
        if let watch = watches.first {
            lines.append(L(id: "watch", mark: .done, title: PhoneCopy.deviceWorks(watch.label)))
        } else if pendingWatch != nil {
            lines.append(L(id: "watch", mark: .working, title: PhoneCopy.addWatch, detail: PhoneCopy.addWatchApprove))
        } else if watchPaired {
            lines.append(L(id: "watch", mark: .notYet, title: PhoneCopy.addWatch, detail: PhoneCopy.addWatchOpen))
        }
        return PhoneSetup(lines: lines, isReady: state.notificationsAllowed && state.pushSeen && state.testApproved && reachable)
    }

    /// The relay's test request for this iPhone, once it has arrived and while it waits.
    private var testWork: Work? {
        state.work.values.lazy.compactMap { try? Work(serializedBytes: $0) }.first { work in
            !work.hasOutcome && (try? Sealing.parseRequest(work.request))?.forDeviceKeyID == state.deviceKeyID
        }
    }

    /// A Watch is paired with this iPhone and has the app; set by the app from WatchConnectivity.
    public var watchPaired = false { didSet { publish() } }
    /// Set while the work stream cannot reach the relay.
    private var connectionFailed: Error? { didSet { publish() } }

    private func accessRequest(_ work: Work, _ members: Members, _ catalogue: Catalogue?) -> AccessRequest? {
        guard let request = try? Sealing.parseRequest(work.request),
              let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { return nil }
        let login = catalogue?.logins.first { $0.loginID == request.loginID }
        let state: AccessRequestState
        let now = Int64(Date().timeIntervalSince1970)
        if work.hasOutcome {
            state = Self.state(work.outcome, now: now)
        } else if let approved = self.state.answered[request.requestID] {
            state = .sendingAnswer(approved ? .approve : .deny)
        } else {
            state = request.answerByUnixSeconds > now ? .waitingForYou(until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds))) : .unanswered
        }
        return AccessRequest(
            id: request.requestID,
            login: RequestedLogin(site: login.map(Self.site) ?? request.loginID, account: login?.account ?? ""),
            agent: RequestingAgent(name: request.agent.isEmpty ? "An agent" : request.agent, machine: machine.label, address: "",
                                   project: request.project.isEmpty ? nil : request.project),
            access: request.purpose == .program ? .program(([request.program.executable] + request.program.arguments).joined(separator: " "))
                : request.purpose == .agentProcess ? .agentProcess : .signIn,
            agentReason: request.reason, askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)), state: state)
    }

    nonisolated static func state(_ lease: Lease, now: Int64) -> AccessRequestState {
        let notAfter = Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds))
        switch lease.state {
        case .waiting: return .waitingForYou(until: Date(timeIntervalSince1970: Double(lease.answerByUnixSeconds)))
        case .approved: return lease.notAfterUnixSeconds > now ? .approved(by: .iPhone, until: notAfter) : .expired(at: notAfter)
        case .denied:
            return .denied(by: .iPhone, reply: lease.reply.isEmpty ? nil : lease.reply,
                           askAgainAfter: lease.retryNotBeforeUnixSeconds > 0 ? Date(timeIntervalSince1970: Double(lease.retryNotBeforeUnixSeconds)) : nil)
        case .ended: return .ended(at: notAfter)
        case .cancelled: return .cancelled
        default: return .unanswered
        }
    }

    nonisolated static func site(_ login: Agentkeyring_V2_Login) -> String {
        login.sites.first.flatMap { URL(string: $0)?.host ?? $0 } ?? login.title
    }

    /// "Approved on your Watch": the kind of device, as Paper names it.
    nonisolated static func shortName(_ kind: Agentkeyring_V2_DeviceKind) -> String? {
        switch kind {
        case .iphone: "iPhone"
        case .watch: "Watch"
        case .mac: "Mac"
        default: nil
        }
    }

    static func howItApproves(_ kind: Agentkeyring_V2_DeviceKind) -> String? {
        switch kind {
        case .iphone: PhoneCopy.faceID
        case .watch: "One tap, unlocked on your wrist"
        case .mac: "Touch ID, with the lid open"
        default: nil
        }
    }

    private func publish() {
        let next = snapshot
        for continuation in subscribers.values { continuation.yield(next) }
    }

    // MARK: Keeping up with the relay

    /// Follows the relay's work stream while the app is open, reconnecting with backoff.
    public func start() {
        guard following == nil, state.endpoint != nil else { return }
        following = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.refreshMembersAndCatalogue()
                    for try await response in try self.relay().stream(Self.method { $0.watchWork = .init() }) {
                        if case let .work(work) = response.result { self.receive(work) }
                        if self.connectionFailed != nil { self.connectionFailed = nil }
                        delay = 1
                    }
                } catch is CancellationError { return }
                catch {
                    PhoneDiagnostics.note("Work stream ended: \(error)")
                    if delay >= 4 { self.connectionFailed = error }
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
    }

    public func stop() { following?.cancel(); following = nil }

    func receive(_ work: Work) {
        guard let request = try? Sealing.parseRequest(work.request) else { return }
        // The relay writes a request once; a later Work for it may only add the outcome.
        if let saved = state.work[request.requestID].flatMap({ try? Work(serializedBytes: $0) }), saved.request != work.request { return }
        var next = state
        next.work[request.requestID] = try? work.serializedData()
        if work.hasOutcome { next.answered[request.requestID] = nil }
        save(next)
    }

    private func refreshMembersAndCatalogue() async throws {
        let relay = try relay()
        if case let .signed(signed) = try await relay.call(Self.method { $0.members = .init() }).result { try accept(members: signed) }
        if case let .signed(signed) = try await relay.call(Self.method { $0.catalogue = .init() }).result { try accept(catalogue: signed) }
    }

    func accept(members signed: SignedDocument) throws {
        if let current = state.members, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return }
        let verified = try Sealing.verifiedMembers(signed, current: members)
        guard verified.devices.contains(where: { $0.keyID == (try? Sealing.keyID(keys.signingPublicKey())) }) else {
            // This iPhone was removed: forget everything it held.
            save(PhoneSavedState())
            return
        }
        var next = state
        next.members = try signed.serializedData()
        save(next)
    }

    func accept(catalogue signed: SignedDocument) throws {
        guard let members else { return }
        if let current = state.catalogue, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return }
        _ = try Sealing.verifiedCatalogue(signed, members: members, current: catalogue)
        var next = state
        next.catalogue = try signed.serializedData()
        save(next)
    }

    var members: Members? {
        state.members.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Members(serializedBytes: $0.payload) }
    }

    var catalogue: Catalogue? {
        state.catalogue.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Catalogue(serializedBytes: $0.payload) }
    }

    private func relay(pinSHA256: Data? = nil) throws -> KeyringRelay {
        guard let endpoint = state.endpoint else { throw KeyringRelayError(code: .unavailable, message: "This iPhone has not joined yet.") }
        return KeyringRelay(endpoint: endpoint, identity: try identity(), pin: members?.relayTlsPublicKey, pinSHA256: pinSHA256)
    }

    static func method(_ build: (inout RelayRequest) -> Void) -> RelayRequest {
        var request = RelayRequest()
        build(&request)
        return request
    }

    // MARK: Answers

    public func approve(_ requestID: String, reusingUnlock: Bool) async throws {
        let work = try await currentWork(requestID)
        let request = try Sealing.parseRequest(work.request)
        guard let members, let catalogue,
              let machine = members.machines.first(where: { $0.machineID == request.machineID }),
              let login = catalogue.logins.first(where: { $0.loginID == request.loginID }),
              login.rule != .blocked, work.hasSealedLogin else {
            throw KeyringRelayError(code: .notAllowed, message: "This iPhone may not approve this request.")
        }
        let context = LAContext()
        defer { context.invalidate() }
        if reusingUnlock { context.touchIDAuthenticationAllowableReuseDuration = 10 }
        try await keys.authorize(context, reason: "Let \(request.agent) on \(machine.label) use \(Self.site(login)) for up to 30 minutes.")
        let secret = try keys.open(work.sealedLogin, context: context)
        let upload = try Sealing.approve(
            request: work.request, secret: secret, sites: login.sites,
            receivingKey: P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey),
            signerKeyID: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        try await send(upload, for: requestID, approving: true)
    }

    public func deny(_ requestID: String, reply: String?) async throws {
        let work = try await currentWork(requestID)
        let upload: AnswerUpload
        if let reply, !reply.isEmpty {
            upload = try Sealing.deny(request: work.request, reply: reply, signerKeyID: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        } else {
            upload = Sealing.plainDeny(requestID: requestID)
        }
        try await send(upload, for: requestID, approving: false)
    }

    private func send(_ upload: AnswerUpload, for requestID: String, approving: Bool) async throws {
        var next = state
        next.answered[requestID] = approving
        save(next)
        do {
            _ = try await relay().call(Self.method { $0.answer = upload })
            PhoneDiagnostics.note("Answer sent to the relay: \(approving ? "approve" : upload.denyRequestID.isEmpty ? "deny with words" : "deny")")
        } catch {
            PhoneDiagnostics.note("Answer not sent: \(error)")
            var undo = state
            undo.answered[requestID] = nil
            save(undo)
            throw error
        }
    }

    /// The Work for a request, from the stream, or asked for when a notification arrived first.
    private func currentWork(_ requestID: String) async throws -> Work {
        if let saved = state.work[requestID], let work = try? Work(serializedBytes: saved), work.hasSealedLogin { return work }
        guard case let .work(work) = try await relay().call(Self.method { $0.getWork.requestID = requestID }).result else {
            throw KeyringRelayError(code: .notFound, message: "The relay has no such request.")
        }
        receive(work)
        return work
    }

    /// Ends an approval early; the machine's next use of the login fails.
    public func stop(_ requestID: String) async throws {
        _ = try await relay().call(Self.method { $0.end.requestID = requestID })
    }

    /// Rule changes need sealing for other openers; not built yet.
    public func setRule(_ rule: PhoneLogin.Rule, forLogin loginID: String) async throws {
        throw KeyringRelayError(code: .unavailable, message: "Not built yet.")
    }

    /// Removes a device or machine: the next Members, signed after Face ID.
    public func remove(device deviceID: String) async throws {
        guard var next = members else { return }
        let context = LAContext()
        defer { context.invalidate() }
        let name = next.devices.first { $0.keyID == deviceID }?.label ?? next.machines.first { $0.machineID == deviceID }?.label ?? ""
        try await keys.authorize(context, reason: "Remove \(name).")
        next.revision += 1
        next.devices.removeAll { $0.keyID == deviceID }
        next.machines.removeAll { $0.machineID == deviceID }
        let signed = try Sealing.signed(next.serializedData(), by: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        _ = try await relay().call(Self.method { $0.publishMembers = signed })
        try accept(members: signed)
    }

    // MARK: Joining and first run

    /// The invitation the Mac app leaves in iCloud Keychain, serialized
    /// `JoinInvite`, as an `agentkeyring://join?invite=` link. Nil when there
    /// is none, for example in the simulator, which has no iCloud Keychain.
    public func invitation() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.joshpalmer.AgentKeyring.invitation",
                                    kSecAttrAccount as String: "relay", kSecAttrSynchronizable as String: true,
                                    kSecAttrAccessGroup as String: "7M8BR7R488.com.joshpalmer.AgentKeyring.shared",
                                    kSecUseDataProtectionKeychain as String: true, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let base64url = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "agentkeyring://join?invite=" + base64url
    }

    /// Joins once per invitation. If this iPhone is not admitted, the Mac issues a
    /// new invitation, and the app tries again with it the next time it opens.
    public func join(invitation: String) async throws {
        guard state.deviceKeyID == nil, !joining else { return }
        joining = true
        defer { joining = false }
        do { try await joinNow(invitation) } catch {
            var next = state
            next.joinProblem = (error as? KeyringRelayError).map { $0.code == .unavailable ? PhoneCopy.cantReachRelay : PhoneCopy.noMac }
                ?? PhoneCopy.cantReachRelay
            save(next)
            PhoneDiagnostics.note("Join failed: \(error)")
            throw error
        }
    }

    private var joining = false

    /// Joins with an invitation link: `agentkeyring://join?invite=<JoinInvite, base64url>`.
    private func joinNow(_ link: String) async throws {
        guard let url = URLComponents(string: link), url.scheme == "agentkeyring", url.host == "join",
              let encoded = url.queryItems?.first(where: { $0.name == "invite" })?.value,
              let bytes = Data(base64URL: encoded), let invite = try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes),
              !invite.relayHost.isEmpty, invite.relayPort > 0, invite.relayPort <= UInt32(UInt16.max) else {
            throw KeyringRelayError(code: .invalid, message: "That is not an Agent Keyring invitation.")
        }
        guard invite.expiresUnixSeconds > Int64(Date().timeIntervalSince1970) else {
            throw KeyringRelayError(code: .notAllowed, message: "The invitation has expired.")
        }
        let host = invite.relayHost, port = UInt16(invite.relayPort), relaySHA = invite.relayTlsSha256
        var next = state
        next.endpoint = try RelayEndpoint(host: host, port: port)
        next.joinProblem = nil
        save(next)
        var device = Agentkeyring_V2_Device()
        device.kind = .iphone
        device.label = "iPhone"
        device.signingPublicKey = try keys.signingPublicKey()
        device.keyID = Sealing.keyID(device.signingPublicKey)
        device.openingPublicKey = try keys.openingPublicKey()
        device.tlsPublicKey = try identity().publicKeySPKI
        device.replyPublicKey = try keys.replyPublicKey()
        device.replyKeyID = Sealing.keyID(device.replyPublicKey)
        var joining = Agentkeyring_V2_JoinRequest()
        joining.device = device
        joining.proof = Sealing.joinProof(secret: invite.secret, joining: joining)
        for try await response in try relay(pinSHA256: relaySHA).stream(Self.method { $0.join = joining }) {
            guard case let .join(status) = response.result else { continue }
            switch status.state {
            case .waiting: continue
            case .approved:
                let members = try Sealing.verifiedMembers(status.members, current: nil)
                guard status.members.signerKeyID == invite.inviterKeyID, members.devices.contains(where: { $0 == device }),
                      Data(SHA256.hash(data: members.relayTlsPublicKey)) == relaySHA else {
                    throw KeyringRelayError(code: .notAllowed, message: "The approval does not match this iPhone.")
                }
                try accept(members: status.members)
                PhoneDiagnostics.note("Joined the relay as \(device.keyID.prefix(16))")
                var joined = state
                joined.deviceKeyID = device.keyID
                save(joined)
                start()
                return
            default:
                save(PhoneSavedState())
                throw KeyringRelayError(code: .notAllowed, message: "The Mac did not add this iPhone.")
            }
        }
    }

    public func notifications(allowed: Bool) async {
        var next = state
        next.notificationsAsked = true
        next.notificationsAllowed = allowed
        save(next)
        if allowed { askForTest() }
    }

    /// Asks the relay for this iPhone's test request: it arrives pushed, like any
    /// request, which shows that requests reach the phone, and opens as a sheet.
    private func askForTest() {
        guard !state.testApproved, !testing else { return }
        testing = true
        Task {
            defer { testing = false }
            do {
                for try await response in try relay().stream(Self.method { $0.testRequest = .init() }) {
                    guard case let .lease(lease) = response.result, lease.state != .waiting else { continue }
                    if lease.state == .approved {
                        var next = state
                        next.testApproved = true
                        save(next)
                    }
                    await reportSelfTest()
                }
            } catch { PhoneDiagnostics.note("Test request failed: \(error)") }
        }
    }

    private var testing = false

    /// Any push reached this iPhone: requests can wake it.
    public func pushArrived() {
        guard !state.pushSeen else { return }
        var next = state
        next.pushSeen = true
        save(next)
        // The test may have finished first; the relay should see the push too.
        if state.testApproved { Task { await reportSelfTest() } }
    }

    /// First run's test request, approved with one Face ID: a signed answer with
    /// no delivery. The same Face ID also opens one of this iPhone's sealed logins,
    /// so both chip keys are tested.
    public func approveTest() async throws {
        guard let work = testWork else { return }
        let context = LAContext()
        defer { context.invalidate() }
        try await keys.authorize(context, reason: "Approve the test request.")
        var answer = Agentkeyring_V2_Answer()
        answer.domain = "agentkeyring.answer.v2"
        answer.requestSha256 = Sealing.sha256(work.request)
        answer.choice = .approve
        answer.decidedUnixSeconds = Int64(Date().timeIntervalSince1970)
        answer.notAfterUnixSeconds = answer.decidedUnixSeconds + 60
        var upload = AnswerUpload()
        upload.answer = try Sealing.signed(answer.serializedData(), by: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        let relay = try relay()
        if case let .sealedLogins(mine) = try? await relay.call(Self.method { $0.sealedLogins = .init() }).result, let first = mine.logins.first {
            do { _ = try keys.open(first, context: context); openingWorks = true }
            catch { openingWorks = false; PhoneDiagnostics.note("The opening key did not open a sealed login: \(error)") }
        }
        _ = try await relay.call(Self.method { $0.answer = upload })
    }

    private var openingWorks: Bool?

    /// What this iPhone found, signed with its reply key, for the relay to keep.
    public func reportSelfTest() async {
        guard let keyID = state.deviceKeyID else { return }
        func check(_ name: String, _ passed: Bool, _ error: String = "") -> Agentkeyring_V2_SelfTestCheck {
            var check = Agentkeyring_V2_SelfTestCheck()
            check.name = name; check.passed = passed; check.error = passed ? "" : error
            return check
        }
        var report = Agentkeyring_V2_SelfTestReport()
        report.domain = "agentkeyring.selftest.v2"
        report.deviceKeyID = keyID
        report.testedUnixSeconds = Int64(Date().timeIntervalSince1970)
        report.checks = [
            check("joined", true),
            check("notifications", state.notificationsAllowed, "notifications are off"),
            check("push reached this iPhone", state.pushSeen, "no push has arrived"),
            check("test request", state.testApproved, "not approved"),
            check("opening key", openingWorks ?? false, openingWorks == nil ? "no sealed login to open" : "did not open"),
        ]
        if let data = state.watchSelfTest,
           let watch = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (name, value) in watch.sorted(by: { $0.key < $1.key }) {
                if let passed = value as? Bool { report.checks.append(check("watch " + name, passed, "false")) }
                if name == "problem", let problem = value as? String, !problem.isEmpty { report.checks.append(check("watch problem", false, problem)) }
            }
        }
        do {
            let signed = try Sealing.signed(report.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
            _ = try await relay().call(Self.method { $0.reportSelfTest = signed })
        } catch { PhoneDiagnostics.note("Self-test report not sent: \(error)") }
    }

    /// The Watch's own self-test, as its app sent it; reported with this iPhone's.
    public func watchTested(_ plist: Data) {
        var next = state
        next.watchSelfTest = plist
        save(next)
        Task { await reportSelfTest() }
    }

    /// Where the Watch posts its answers: the relay's own address, over HTTPS.
    public var relayAnswerURL: String? { state.endpoint.map { "https://\($0.host):\($0.port)/v2/answer" } }

    public func approveDevice(_ id: String) async throws { try await allowWatch() }

    public func denyDevice(_ id: String) async {
        var next = state
        next.watchDevice = nil; next.watchPush = nil
        save(next)
    }

    /// The Watch's app sent its keys, its push address, or both. The keys are
    /// kept until he says yes or not now; the push address can come later, on a
    /// real Watch too, and goes to the relay as soon as the Watch is listed.
    public func watchOffered(device: Data?, push: Data?) {
        let parsed = device.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
        let pushKeyID = push.flatMap { try? Agentkeyring_V2_PushRegistration(serializedBytes: $0) }?.deviceKeyID
        let listed = members?.devices.first { $0.kind == .watch && $0.keyID == (parsed?.keyID ?? pushKeyID) }
        if listed != nil {
            if let push { Task { await registerWatchPush(push) } }
            return
        }
        guard let parsed, parsed.kind == .watch, let device else {
            if let push { var next = state; next.watchPush = push; save(next) }
            return
        }
        var next = state
        next.watchDevice = device
        if let push { next.watchPush = push }
        save(next)
    }

    private func registerWatchPush(_ bytes: Data) async {
        do {
            let push = try Agentkeyring_V2_PushRegistration(serializedBytes: bytes)
            _ = try await relay().call(Self.method { $0.registerPush = push })
            var done = state
            done.watchPush = nil
            save(done)
        } catch { PhoneDiagnostics.note("Watch push address not registered: \(error)") }
    }

    /// After one Face ID: the Watch joins the signed list of devices, gets
    /// every login sealed to its own key, and its push address goes to the relay.
    public func allowWatch() async throws {
        guard var next = members, let deviceBytes = state.watchDevice else { return }
        let watch = try Agentkeyring_V2_Device(serializedBytes: deviceBytes)
        let watchKey = try P256.KeyAgreement.PublicKey(x963Representation: watch.openingPublicKey)
        let context = LAContext()
        defer { context.invalidate() }
        try await keys.authorize(context, reason: "Let your Apple Watch approve requests.")
        let relay = try relay()
        guard case let .sealedLogins(mine) = try await relay.call(Self.method { $0.sealedLogins = .init() }).result else {
            throw KeyringRelayError(code: .unavailable, message: "The relay sent no sealed logins.")
        }
        var forWatch = Agentkeyring_V2_SealedLogins()
        forWatch.logins = try mine.logins.map { try Sealing.seal(keys.open($0, context: context), to: watchKey, openerID: watch.keyID) }
        next.revision += 1
        next.devices.append(watch)
        let signed = try Sealing.signed(next.serializedData(), by: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        _ = try await relay.call(Self.method { $0.publishMembers = signed })
        try accept(members: signed)
        _ = try await relay.call(Self.method { $0.publishSealedLogins = forWatch })
        PhoneDiagnostics.note("Watch added: \(forWatch.logins.count) logins sealed to it")
        var done = state
        done.watchDevice = nil
        save(done)
        if let push = state.watchPush { await registerWatchPush(push) }
    }

    /// The signed Members bytes, for the Watch.
    public var signedMembers: Data? { state.members }

    /// Tells the relay where to wake this iPhone, and the key its notices are sealed to.
    public func registerPush(token: Data, topic: String, production: Bool) async throws {
        var registration = Agentkeyring_V2_PushRegistration()
        registration.deviceKeyID = try Sealing.keyID(keys.signingPublicKey())
        registration.apnsToken = token
        registration.apnsTopic = topic
        registration.apnsProduction = production
        registration.noticePublicKey = try keys.noticePublicKey()
        _ = try await relay().call(Self.method { $0.registerPush = registration })
    }

    // MARK: For the notification service extension

    /// The request a push is about, as the Lock Screen shows it: the notice
    /// opened, the login and machine named from the saved Catalogue and Members.
    nonisolated public static func notifiedRequest(_ userInfo: [AnyHashable: Any], shared: PhoneSharedContext,
                                       open: (Agentkeyring_V2_Notice, String) throws -> Agentkeyring_V2_Work) -> (request: AccessRequest, answeredBy: String?)? {
        let log = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Notice")
        func fail(_ step: String) -> (request: AccessRequest, answeredBy: String?)? {
            log.error("Could not name the request: \(step, privacy: .public)")
            PhoneDiagnostics.note("Could not name the request: \(step)")
            return nil
        }
        guard let base64 = userInfo["akr"] as? String, let bytes = Data(base64Encoded: base64),
              let notice = try? Agentkeyring_V2_Notice(serializedBytes: bytes) else { return fail("no notice in the push") }
        guard let saved = shared.read() else { return fail("the shared keychain item is missing") }
        guard let keyID = saved.deviceKeyID else { return fail("no device key id saved") }
        let work: Agentkeyring_V2_Work
        do { work = try open(notice, keyID) } catch { return fail("the notice did not open: \(error)") }
        guard let members = saved.members.flatMap({ try? SignedDocument(serializedBytes: $0) }).flatMap({ try? Members(serializedBytes: $0.payload) })
        else { return fail("no Members saved") }
        let catalogue = saved.catalogue.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Catalogue(serializedBytes: $0.payload) }
        guard let request = try? Sealing.parseRequest(work.request) else { return fail("the request did not parse") }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { return fail("unknown machine") }
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }) else { return fail("login not in the saved catalogue") }
        let outcome = work.hasOutcome ? state(work.outcome, now: Int64(Date().timeIntervalSince1970))
            : .waitingForYou(until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
        return (AccessRequest(id: request.requestID, login: RequestedLogin(site: site(login), account: login.account),
                              agent: RequestingAgent(name: request.agent, machine: machine.label, address: "",
                                                     project: request.project.isEmpty ? nil : request.project),
                              access: .signIn, agentReason: request.reason,
                              askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)), state: outcome),
                work.hasOutcome ? members.devices.first { $0.label == work.outcome.answeredBy }.flatMap { shortName($0.kind) } : nil)
    }

    // MARK: Saving

    private var stateURL: URL { directory.appending(path: "phone-v2.plist") }

    private func save(_ next: PhoneSavedState) {
        let sharedChanged = next.members != state.members || next.catalogue != state.catalogue || next.deviceKeyID != state.deviceKeyID
        state = next
        if sharedChanged { shared.write(next) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            #if os(iOS)
            try encoder.encode(next).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try encoder.encode(next).write(to: stateURL, options: .atomic)
            #endif
        } catch { logger.error("Could not save the iPhone's state: \(String(describing: error), privacy: .public)") }
        publish()
    }
}

extension Data {
    /// Base64url with no padding, as invitation links carry it.
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
