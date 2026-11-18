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
    var watchAsked = false
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
        guard let members else { return PhoneSnapshot(setup: .scanCode) }
        let catalogue = self.catalogue
        // There is no Watch app yet, so first run does not offer the Watch.
        let setup: PhoneSetup = !state.notificationsAsked ? .turnOnNotifications : .ready
        let requests = state.work.values.compactMap { try? Work(serializedBytes: $0) }.compactMap { accessRequest($0, members, catalogue) }
        let logins = (catalogue?.logins ?? []).map { login in
            PhoneLogin(id: login.loginID, site: Self.site(login), account: login.account,
                       rule: login.rule == .automatic ? .automatic : login.rule == .blocked ? .blocked
                           : (login.phoneAndWatchOnly ? .askOnIPhoneOrWatch : .ask))
        }
        let mine = try? Sealing.keyID(keys.signingPublicKey())
        let devices = members.devices.map { device in
            PhoneDevice(id: device.keyID, name: device.label, detail: Self.howItApproves(device.kind), role: .approves,
                        isThisIPhone: device.keyID == mine)
        } + members.machines.map { PhoneDevice(id: $0.machineID, name: $0.label, role: .asks) }
        return PhoneSnapshot(setup: setup, requests: requests, logins: logins, devices: devices)
    }

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
                        delay = 1
                    }
                } catch is CancellationError { return }
                catch { PhoneDiagnostics.note("Work stream ended: \(error)") }
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
        try await approve(requestID, reusingUnlock: reusingUnlock, prompting: true)
    }

    /// Approve pressed on the Lock Screen, handled in the background: only the
    /// Face ID that unlocked the phone a moment ago may count. Fails rather than
    /// show Face ID, which iOS does not allow in the background.
    public func approveFromLockScreen(_ requestID: String) async throws {
        try await approve(requestID, reusingUnlock: true, prompting: false)
    }

    private func approve(_ requestID: String, reusingUnlock: Bool, prompting: Bool) async throws {
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
        context.interactionNotAllowed = !prompting
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

    /// Version 2 has no way yet for a device to end an approval early.
    public func stop(_ requestID: String) async throws {
        throw KeyringRelayError(code: .unavailable, message: "Not in the protocol yet.")
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

    /// The code on the Mac: `agentkeyring://join?host=…&port=…&relay=<SHA-256 of the relay's TLS key, hex>`.
    public func join(scannedCode: String) async throws {
        guard let url = URLComponents(string: scannedCode), url.scheme == "agentkeyring", url.host == "join",
              let host = url.queryItems?.first(where: { $0.name == "host" })?.value,
              let port = url.queryItems?.first(where: { $0.name == "port" })?.value.flatMap(UInt16.init),
              let relayHex = url.queryItems?.first(where: { $0.name == "relay" })?.value, let relaySHA = Data(hex: relayHex) else {
            throw KeyringRelayError(code: .invalid, message: "That is not an Agent Keyring code.")
        }
        var next = state
        next.endpoint = try RelayEndpoint(host: host, port: port)
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
        for try await response in try relay(pinSHA256: relaySHA).stream(Self.method { $0.join.device = device }) {
            guard case let .join(status) = response.result else { continue }
            switch status.state {
            case .waiting: continue
            case .approved:
                let members = try Sealing.verifiedMembers(status.members, current: nil)
                guard members.devices.contains(where: { $0 == device }),
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

    public func turnOnNotifications() async {
        var next = state
        next.notificationsAsked = true
        save(next)
    }

    /// Adding the Watch needs the Watch app; until then first run skips it.
    public func allowWatch() async throws { skipWatch() }

    public func skipWatch() {
        var next = state
        next.watchAsked = true
        save(next)
    }

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
