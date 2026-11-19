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
    /// Where first run stands once joined; nil reads as its first step after joining.
    var firstRun: PhoneFirstRun?
    /// A push reached this iPhone since it joined.
    var pushSeen = false
    /// What the Watch found when it tested itself, as its app sent it (a property list).
    var watchSelfTest: Data?
    /// The Watch's Device and PushRegistration, serialized, as its app sent them, until it is added or refused.
    var watchDevice: Data?
    var watchPush: Data?
    /// The notification settings; nil means the defaults.
    var settings: NotificationSettings?
    /// He closed the "Add Apple Watch" card.
    var watchCardDismissed: Bool?
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
        shared.settings = state.settings
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
        firstRun = state.deviceKeyID == nil ? .start : (state.firstRun ?? .notifications).restored
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
            var snapshot = PhoneSnapshot(firstRun: firstRun, practiceRequest: practiceOpen)
            snapshot.settings = phoneSettings
            return snapshot
        }
        let catalogue = self.catalogue
        let requests = state.work.values.compactMap { try? Work(serializedBytes: $0) }.compactMap { accessRequest($0, members, catalogue) }
        let logins = (catalogue?.logins ?? []).map { login in
            PhoneLogin(id: login.loginID, site: Self.site(login), account: login.account,
                       rule: login.rule == .automatic ? .automatic : login.rule == .blocked ? .blocked
                           : .ask)
        }
        let mine = state.deviceKeyID
        // "Face ID · Ready" once the device's latest self-test passed; Apple Watch's comes in this iPhone's report.
        func detail(_ how: String?, ready: Bool) -> String? { ready ? [how, PhoneCopy.ready].compactMap { $0 }.joined(separator: " · ") : how }
        let devices = members.devices.map { device in
            PhoneDevice(id: device.keyID, name: device.label, detail: detail(Self.howItApproves(device.kind), ready: readyDevices.contains(device.keyID)),
                        role: .approves, isThisIPhone: device.keyID == mine)
        } + members.machines.map { machine in
            // The computer that stays on passes requests to the iPhone and Apple Watch.
            let passes = machine.machineID == members.relayMachineID ? PhoneCopy.passesRequests : nil
            return PhoneDevice(id: machine.machineID, name: machine.label, detail: detail(passes, ready: readyDevices.contains(machine.machineID)), role: .asks)
        }
        let pendingWatch = state.watchDevice.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
        var snapshot = PhoneSnapshot(firstRun: firstRun, requests: requests, logins: logins, devices: devices)
        snapshot.joined = true
        snapshot.practiceRequest = practiceOpen
        snapshot.relayName = members.machines.first { $0.machineID == members.relayMachineID }?.label
        snapshot.watchPaired = watchPaired
        snapshot.notices = notices(members: members, pendingWatch: pendingWatch)
        snapshot.settings = phoneSettings
        snapshot.deviceRequest = pendingWatch.map { PhoneDeviceRequest(id: $0.keyID, name: $0.label, detail: PhoneCopy.pairedWithThisIPhone) }
        return snapshot
    }

    /// Where first run stands: the one state every first-run screen and step follows.
    private(set) var firstRun = PhoneFirstRun.start

    /// Moves first run on by the board's table, keeps the step once joined, and
    /// starts what the new state asks for.
    private func apply(_ event: PhoneFirstRun.Event) {
        let next = firstRun.on(event)
        guard next != firstRun else { return }
        firstRun = next
        if state.deviceKeyID != nil {
            var saved = state
            saved.firstRun = next
            save(saved)
        } else { publish() }
        if next == .practiceWaiting(arrived: false) { beginPractice() }
        if next == .settingUpNotifications { askForPractice() }
    }

    /// A tap on a first-run screen, or what iOS answered about notifications.
    public func firstRun(_ event: PhoneFirstRun.Event) async {
        if case let .notificationsAnswered(allowed) = event { notificationsAllowed = allowed }
        if event == .askAgain { failedJoin = nil }
        apply(event)
    }

    /// The practice request while it is open: on its own before joining, the relay's after.
    private var practiceOpen: AccessRequest? {
        switch firstRun {
        case .welcome(_, practising: true): .practice()
        case .practice: testWork.flatMap { work in (try? Sealing.parseRequest(work.request)).map(Self.practiceRequest) }
        default: nil
        }
    }

    /// The practice request in the real request's layout, with the board's words.
    nonisolated static func practiceRequest(_ request: KeyringRequest) -> AccessRequest {
        .practice(id: request.requestID, askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)),
                  until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
    }

    /// One sentence in Activity for what needs him, after first run.
    private func notices(members: Members, pendingWatch: Agentkeyring_V2_Device?) -> [PhoneNotice] {
        var notices: [PhoneNotice] = []
        if connectionFailed != nil { notices.append(.relayOffline(members.machines.first { $0.machineID == members.relayMachineID }?.label)) }
        else if !pushRegistered && !state.pushSeen { notices.append(.stillConnecting) }
        if watchPaired, pendingWatch == nil, !members.devices.contains(where: { $0.kind == .watch }), state.watchCardDismissed != true {
            notices.append(.addAppleWatch)
        }
        return notices
    }

    private var phoneSettings: PhoneSettings {
        let saved = state.settings ?? NotificationSettings()
        return PhoneSettings(timeSensitive: saved.timeSensitive, quietHours: saved.quietHours, quietFrom: saved.quietFrom, quietTo: saved.quietTo)
    }

    public func dismiss(_ notice: PhoneNotice) async {
        guard notice == .addAppleWatch else { return }
        var next = state
        next.watchCardDismissed = true
        save(next)
    }

    /// Kept for the extension in the shared keychain item, and handed to Apple Watch.
    public func setSettings(_ settings: PhoneSettings) async {
        var saved = NotificationSettings()
        saved.timeSensitive = settings.timeSensitive; saved.quietHours = settings.quietHours
        saved.quietFrom = settings.quietFrom; saved.quietTo = settings.quietTo
        var next = state
        next.settings = saved
        save(next)
        onSettingsChanged?()
    }

    /// The app hands new settings to Apple Watch.
    public var onSettingsChanged: (() -> Void)?
    public var notificationSettings: NotificationSettings { state.settings ?? NotificationSettings() }

    /// The relay's latest practice request for this iPhone, once it has arrived and while it waits.
    private var testWork: Work? {
        state.work.values.compactMap { try? Work(serializedBytes: $0) }
            .filter { !$0.hasOutcome && isPracticeWork($0) }
            .max { (try? Sealing.parseRequest($0.request).askedUnixSeconds) ?? 0 < (try? Sealing.parseRequest($1.request).askedUnixSeconds) ?? 0 }
    }

    private func isPracticeWork(_ work: Work) -> Bool {
        guard let mine = state.deviceKeyID else { return false }
        return (try? Sealing.parseRequest(work.request))?.forDeviceKeyID == mine
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
            state = Self.state(work.outcome, now: now, members: members)
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
            access: .login,
            agentReason: request.reason, askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)), state: state)
    }

    nonisolated static func state(_ lease: Lease, now: Int64, members: Members? = nil) -> AccessRequestState {
        let notAfter = Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds))
        // "Approved on your Mac" when a Mac answered, by the label the relay records.
        // Only a Mac in the list of devices counts: any computer could name itself in what the relay records.
        let byMac = members?.devices.contains { $0.kind == .mac && $0.label == lease.answeredBy } == true
        let surface: ApprovalSurface = byMac ? .mac : .iPhone
        switch lease.state {
        case .waiting: return .waitingForYou(until: Date(timeIntervalSince1970: Double(lease.answerByUnixSeconds)))
        case .approved: return lease.notAfterUnixSeconds > now ? .approved(by: surface, until: notAfter) : .expired(at: notAfter)
        case .denied:
            return .denied(by: surface, reply: lease.reply.isEmpty ? nil : lease.reply,
                           askAgainAfter: lease.retryNotBeforeUnixSeconds > 0 ? Date(timeIntervalSince1970: Double(lease.retryNotBeforeUnixSeconds)) : nil)
        case .ended: return .ended(at: notAfter)
        case .cancelled: return .cancelled
        default: return .unanswered
        }
    }

    nonisolated static func rule(_ login: Agentkeyring_V2_Login) -> PhoneLogin.Rule {
        login.rule == .automatic ? .automatic : login.rule == .blocked ? .blocked : .ask
    }

    nonisolated static func site(_ login: Agentkeyring_V2_Login) -> String {
        login.sites.first.flatMap { URL(string: $0)?.host ?? $0 } ?? login.title
    }

    /// "Approved on your Watch": the kind of device, as Paper names it.
    nonisolated static func shortName(_ kind: Agentkeyring_V2_DeviceKind) -> String? {
        switch kind {
        case .iphone: "iPhone"
        case .watch: "Apple Watch"
        case .mac: "Mac"
        default: nil
        }
    }

    static func howItApproves(_ kind: Agentkeyring_V2_DeviceKind) -> String? {
        switch kind {
        case .iphone: PhoneCopy.faceID
        case .watch: "One tap"
        case .mac: "Touch ID"
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
        guard state.deviceKeyID != nil else { lookForMac(); return }
        // After a relaunch, or a practice request lost while the app was away: ask for it again.
        if firstRun == .practiceWaiting(arrived: false), practiceTimer == nil { beginPractice() }
        else if firstRun.wantsPractice, practiceTask == nil, pushRegistered || firstRun == .settingUpNotifications { askForPractice() }
        guard following == nil, state.endpoint != nil else { return }
        following = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.refreshMembersAndCatalogue()
                    await self.recheckWaiting()
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

    public func stop() {
        following?.cancel(); following = nil
        looking?.cancel(); looking = nil
    }

    func receive(_ work: Work) {
        guard let request = try? Sealing.parseRequest(work.request) else { return }
        // The relay writes a request once; a later Work for it may only add the outcome.
        if let saved = state.work[request.requestID].flatMap({ try? Work(serializedBytes: $0) }), saved.request != work.request { return }
        var next = state
        next.work[request.requestID] = try? work.serializedData()
        if work.hasOutcome { next.answered[request.requestID] = nil }
        save(next)
        // The practice request reaches first run here too, so its end is seen even if its own stream was lost.
        if isPracticeWork(work) {
            if work.hasOutcome { practiceOutcome = work.outcome.state; apply(.practiceEnded) }
            else { apply(.practiceArrived(pushExpected: notificationsAllowed && pushRegistered)) }
            return
        }
        // A machine or login this iPhone has not seen yet: the lists changed since it last looked.
        let unknownMachine = !request.machineID.isEmpty && members?.machines.contains { $0.machineID == request.machineID } == false
        let unknownLogin = !request.loginID.isEmpty && catalogue?.logins.contains { $0.loginID == request.loginID } != true
        if unknownMachine || unknownLogin { Task { try? await refreshMembersAndCatalogue() } }
    }

    /// A new stream sends only the requests still waiting, so one answered or
    /// ended while this iPhone was away would look as if it still waited: ask for each.
    private func recheckWaiting() async {
        let open = state.work.compactMap { id, bytes in (try? Work(serializedBytes: bytes)).flatMap { $0.hasOutcome ? nil : id } }
        for id in open {
            if case let .work(work)? = try? await relay().call(Self.method { $0.getWork.requestID = id }).result { receive(work) }
        }
    }

    private func refreshMembersAndCatalogue() async throws {
        let relay = try relay()
        // Each revision since the one held, in turn: a later one may be signed by
        // a device that only an earlier one added.
        if let revision = members?.revision {
            if case let .membersChain(chain) = try await relay.call(Self.method { $0.membersSince = revision }).result {
                for document in chain.revisions { try accept(members: document) }
            }
        } else if case let .signed(signed) = try await relay.call(Self.method { $0.members = .init() }).result {
            try accept(members: signed)
        }
        if case let .signed(signed) = try await relay.call(Self.method { $0.catalogue = .init() }).result { try accept(catalogue: signed) }
        if case let .selfTests(tests) = try? await relay.call(Self.method { $0.selfTests = .init() }).result { noteSelfTests(tests) }
    }

    func accept(members signed: SignedDocument) throws {
        if let current = state.members, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return }
        let verified = try Sealing.verifiedMembers(signed, current: members)
        guard verified.devices.contains(where: { $0.keyID == (try? Sealing.keyID(keys.signingPublicKey())) }) else {
            // This iPhone was removed: forget everything it held, and look for a Mac again.
            save(PhoneSavedState())
            following?.cancel(); following = nil
            practiceTask?.cancel(); practiceTask = nil
            practiceTimer?.cancel(); practiceTimer = nil
            lookingSince = nil
            apply(.removed)
            lookForMac()
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
        if case .welcome(_, practising: true) = firstRun, requestID == AccessRequest.localPracticeID {
            let context = LAContext()
            defer { context.invalidate() }
            try await keys.authorize(context, reason: "Approve the practice request.")
            return apply(.closePractice)
        }
        if isPractice(requestID) { return try await approveTest() }
        let work = try await currentWork(requestID)
        let request = try Sealing.parseRequest(work.request)
        guard let members, let login = try? Sealing.signedLogin(for: request, in: catalogue),
              let machine = members.machines.first(where: { $0.machineID == request.machineID }),
              work.hasSealedLogin else {
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
        if case .welcome(_, practising: true) = firstRun, requestID == AccessRequest.localPracticeID { return apply(.closePractice) }
        if isPractice(requestID) { return await denyTest() }
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
    /// Changes a login's rule from the Logins tab, after one Face ID.
    public func setRule(_ rule: PhoneLogin.Rule, forLogin loginID: String) async throws {
        guard let old = catalogue?.logins.first(where: { $0.loginID == loginID }) else { return }
        var change = Agentkeyring_V2_RuleChange()
        change.loginID = loginID
        switch rule {
        case .ask: change.rule = .ask
        case .automatic: change.rule = .automatic
        case .blocked: change.rule = .blocked
        }
        guard change.rule != old.rule || change.phoneAndWatchOnly != old.phoneAndWatchOnly else { return }
        let context = LAContext()
        defer { context.invalidate() }
        // Making a password Automatic names the computers that will receive it; the same Face ID switches them on.
        let computers = members?.machines.map(\.label) ?? []
        let reason = rule == .automatic && !computers.isEmpty
            ? PhoneCopy.automaticReason(site: Self.site(old), from: Self.rule(old), computers: computers)
            : "Set \(Self.site(old)) to \(PhoneCopy.rule(rule))."
        try await keys.authorize(context, reason: reason)
        try await publish([change], context: context)
    }

    /// The next Catalogue with these changes, signed with this context's Face ID,
    /// and the sealed copies the new rules need: Automatic seals a login to every
    /// machine allowed Automatic logins; leaving Automatic withdraws those copies;
    /// leaving "Ask on iPhone or Watch" seals it again to each Mac.
    private func publish(_ changes: [Agentkeyring_V2_RuleChange], context: LAContext) async throws {
        guard var members, var next = catalogue else { return }
        let relay = try relay()
        // No computer receives Automatic passwords in advance: the first Automatic password switches them all on.
        let anyToAutomatic = changes.contains { change in
            change.rule == .automatic && next.logins.first { $0.loginID == change.loginID }?.rule != .automatic
        }
        if anyToAutomatic, members.machines.contains(where: { !$0.automaticAllowed }) {
            for index in members.machines.indices { members.machines[index].automaticAllowed = true }
            members.revision += 1
            let signed = try Sealing.signed(members.serializedData(), by: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
            _ = try await relay.call(Self.method { $0.publishMembers = signed })
            try accept(members: signed)
        }
        var mine: [String: SealedLogin] = [:]
        var batch = Agentkeyring_V2_SealedLogins()
        for change in changes {
            guard let index = next.logins.firstIndex(where: { $0.loginID == change.loginID }) else { continue }
            let old = next.logins[index]
            var login = old
            login.rule = change.rule
            login.phoneAndWatchOnly = change.phoneAndWatchOnly
            let toAutomatic = login.rule == .automatic && old.rule != .automatic
            let backToMac = old.phoneAndWatchOnly && !login.phoneAndWatchOnly
            if toAutomatic || backToMac {
                if mine.isEmpty, case let .sealedLogins(held) = try await relay.call(Self.method { $0.sealedLogins = .init() }).result {
                    mine = Dictionary(held.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
                }
                guard let sealed = mine[change.loginID] else {
                    throw KeyringRelayError(code: .notFound, message: "This iPhone holds no copy of that login.")
                }
                let secret = try keys.open(sealed, context: context)
                if toAutomatic {
                    for machine in members.machines where machine.automaticAllowed {
                        batch.logins.append(try Sealing.seal(secret, to: P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey),
                                                             openerID: machine.machineID))
                    }
                }
                if backToMac {
                    for mac in members.devices where mac.kind == .mac {
                        batch.logins.append(try Sealing.seal(secret, to: P256.KeyAgreement.PublicKey(x963Representation: mac.openingPublicKey),
                                                             openerID: mac.keyID))
                    }
                }
            }
            // Leaving Automatic, or becoming Blocked: no computer keeps a copy. (Withdrawing devices' own copies
            // of a Blocked password needs the relay to take that, which the protocol does not yet carry.)
            if (old.rule == .automatic && login.rule != .automatic) || (login.rule == .blocked && old.rule != .blocked) {
                batch.withdrawnLoginIds.append(change.loginID)
            }
            next.logins[index] = login
        }
        next.revision += 1
        let signed = try Sealing.signed(next.serializedData(), by: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        _ = try await relay.call(Self.method { $0.publishCatalogue = signed })
        try accept(catalogue: signed)
        if !batch.logins.isEmpty || !batch.withdrawnLoginIds.isEmpty {
            _ = try await relay.call(Self.method { $0.publishSealedLogins = batch })
        }
    }







    /// Device key ids and machine ids whose latest self-test passed every check that matters.
    private var readyDevices: Set<String> = [] { didSet { publish() } }

    private func noteSelfTests(_ tests: Agentkeyring_V2_SelfTests) {
        guard let members else { return }
        var ready: Set<String> = []
        for signed in tests.reports {
            guard (try? Sealing.verify(signed, members: members, allowReplyKey: true)) != nil,
                  let report = try? Agentkeyring_V2_SelfTestReport(serializedBytes: signed.payload) else { continue }
            // Being off the wrist at the moment of the test is not a fault.
            let mine = report.checks.filter { !$0.name.hasPrefix("watch ") }
            if !mine.isEmpty, mine.allSatisfy(\.passed) { ready.insert(report.deviceKeyID) }
            let watch = report.checks.filter { $0.name.hasPrefix("watch ") && $0.name != "watch onWristAndUnlocked" }
            if !watch.isEmpty, watch.allSatisfy(\.passed), let id = members.devices.first(where: { $0.kind == .watch })?.keyID { ready.insert(id) }
        }
        readyDevices = ready
    }

    /// Removes a device or machine: the next Members, signed after Face ID.
    public func remove(device deviceID: String) async throws {
        guard var next = members else { return }
        let context = LAContext()
        defer { context.invalidate() }
        let name = next.devices.first { $0.keyID == deviceID }?.label ?? next.machines.first { $0.machineID == deviceID }?.label ?? ""
        try await keys.authorize(context, reason: "Remove \(name).")
        next.revision += 1
        // A Mac both approves and has agents that ask: one Remove takes both.
        let mac = next.devices.first { $0.keyID == deviceID && $0.kind == .mac }
        next.devices.removeAll { $0.keyID == deviceID }
        next.machines.removeAll { machine in
            machine.machineID == deviceID
                || mac.map { !$0.tlsPublicKey.isEmpty && $0.tlsPublicKey == machine.tlsPublicKey || $0.label == machine.label } == true
        }
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
                                    kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String ?? "",
                                    kSecUseDataProtectionKeychain as String: true, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let base64url = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "agentkeyring://join?invite=" + base64url
    }

    /// While the app is in front and this iPhone has not joined, it keeps looking
    /// for the Mac's invitation and joins with it. An invitation whose relay does
    /// not answer, has expired or whose join ended counts as not there yet, and is
    /// tried again after a short wait, so a Mac set up later is found by itself.
    /// First run decides whether it may ask: not after the Mac refused, until Ask Again.
    private func lookForMac() {
        guard looking == nil, state.deviceKeyID == nil else { return }
        if lookingSince == nil { lookingSince = Date() }
        looking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state.deviceKeyID == nil else { break }
                if self.firstRun.mayJoin, let link = self.linkInvitation ?? self.invitation(),
                   self.failedJoin.map({ $0.link != link || Date().timeIntervalSince($0.at) > 30 }) ?? true {
                    do { try await self.joinNow(link) } catch {
                        self.failedJoin = (link, Date())
                        PhoneDiagnostics.note("No Mac yet: \(error)")
                    }
                }
                if self.state.deviceKeyID != nil { break }
                self.apply(.noMac(longWait: Date().timeIntervalSince(self.lookingSince ?? Date()) >= 120))
                try? await Task.sleep(for: .seconds(3))
            }
            self?.looking = nil
        }
    }

    private var looking: Task<Void, Never>?
    /// When this launch began looking for the Mac.
    private var lookingSince: Date?
    /// The last invitation that did not lead to joining, and when.
    private var failedJoin: (link: String, at: Date)?
    /// An invitation opened as a link (the simulator has no iCloud Keychain).
    private var linkInvitation: String?

    public func join(invitation: String) async throws {
        guard state.deviceKeyID == nil else { return }
        // The loop picks it up on its next look; a second join with the same keys would only race it.
        linkInvitation = invitation
        lookForMac()
    }

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
        let relaySHA = invite.relayTlsSha256
        let endpoint = try RelayEndpoint(host: invite.relayHost, port: UInt16(invite.relayPort))
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
        let relay = KeyringRelay(endpoint: endpoint, identity: try identity(), pin: nil, pinSHA256: relaySHA)
        for try await response in try relay.stream(Self.method { $0.join = joining }) {
            guard case let .join(status) = response.result else { continue }
            switch status.state {
            case .waiting: apply(.joinWaiting(mac: nil))
            case .refused:
                apply(.joinRefused(mac: nil))
                throw KeyringRelayError(code: .notAllowed, message: "The Mac refused this iPhone.")
            case .approved:
                let members = try Sealing.verifiedMembers(status.members, current: nil)
                guard status.members.signerKeyID == invite.inviterKeyID, members.devices.contains(where: { $0 == device }),
                      Data(SHA256.hash(data: members.relayTlsPublicKey)) == relaySHA else {
                    throw KeyringRelayError(code: .notAllowed, message: "The approval does not match this iPhone.")
                }
                try accept(members: status.members)
                PhoneDiagnostics.note("Joined the relay as \(device.keyID.prefix(16))")
                var joined = state
                joined.endpoint = endpoint
                joined.deviceKeyID = device.keyID
                save(joined)
                lookingSince = nil
                apply(.joined)
                start()
                return
            default:
                throw KeyringRelayError(code: .notAllowed, message: "The join ended: \(status.state).")
            }
        }
    }

    /// What iOS allows, as the app last read it: for the self-test and whether a practice push will come.
    private var notificationsAllowed = false

    /// The relay has this launch's push address. The practice request waits for
    /// it, so that its push can show that requests reach this iPhone.
    private var pushRegistered = false { didSet { publish() } }

    /// How the last practice request ended, for the self-test report.
    private var practiceOutcome: Agentkeyring_V2_LeaseState?

    /// First run waits for the practice request: 30 seconds, then the screen says why it hasn't come.
    private func beginPractice() {
        practiceTimer?.cancel()
        practiceTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            self.practiceTimer = nil
            self.apply(.practiceTimedOut(pushAddress: self.pushRegistered))
        }
        if pushRegistered { askForPractice() }
    }

    private var practiceTimer: Task<Void, Never>?
    private var practiceTask: Task<Void, Never>?
    /// Which ask is the current one, so that a replaced ask cannot clear its successor.
    private var practiceAsk = 0

    /// Asks the relay for this iPhone's practice request: it arrives pushed, like
    /// any request, which shows that requests reach the phone. A new ask replaces
    /// the last, and any of its requests still waiting here.
    private func askForPractice() {
        practiceTask?.cancel()
        practiceAsk += 1
        let ask = practiceAsk
        var next = state
        next.work = next.work.filter { _, bytes in (try? Work(serializedBytes: bytes)).map { $0.hasOutcome || !isPracticeWork($0) } ?? true }
        save(next)
        practiceTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await response in try self.relay().stream(Self.method { $0.testRequest = .init() }) {
                    guard case let .lease(lease) = response.result, lease.state != .waiting else { continue }
                    self.practiceOutcome = lease.state
                    self.apply(.practiceEnded)
                    await self.reportSelfTest()
                }
            } catch { PhoneDiagnostics.note("Practice request failed: \(error)") }
            if self.practiceAsk == ask { self.practiceTask = nil }
        }
    }

    private func isPractice(_ id: String) -> Bool {
        testWork.flatMap { try? Sealing.parseRequest($0.request).requestID } == id
    }

    /// A tap on a notification: the practice request opens over first run.
    public func notificationOpened(_ requestID: String) {
        if isPractice(requestID) { apply(.practiceTapped) }
    }

    func denyTest() async {
        guard let work = testWork, let id = try? Sealing.parseRequest(work.request).requestID else { return }
        _ = try? await relay().call(Self.method { $0.answer = Sealing.plainDeny(requestID: id) })
    }

    /// Any push reached this iPhone: requests can wake it.
    public func pushArrived() {
        guard !state.pushSeen else { return }
        var next = state
        next.pushSeen = true
        save(next)
        // The practice request may have finished first; the relay should see the push too.
        if practiceOutcome != nil { Task { await reportSelfTest() } }
    }

    /// First run's test request, approved with one Face ID: a signed answer with
    /// no delivery. The same Face ID also opens one of this iPhone's sealed logins,
    /// so both chip keys are tested.
    func approveTest() async throws {
        guard let work = testWork else { return }
        let context = LAContext()
        defer { context.invalidate() }
        try await keys.authorize(context, reason: "Approve the practice request.")
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
            check("notifications", notificationsAllowed, "notifications are off"),
            check("push address", pushRegistered, "not registered with the relay"),
            check("push reached this iPhone", state.pushSeen, "no push has arrived"),
            check("test request", practiceOutcome == .approved, practiceOutcome.map { "ended \($0)" } ?? "not answered"),
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
    /// The signed Catalogue, as the relay sent it, for Apple Watch.
    public var signedCatalogue: Data? { state.catalogue }

    /// Tells the relay where to wake this iPhone, and the key its notices are sealed to.
    public func registerPush(token: Data, topic: String, production: Bool) async throws {
        var registration = Agentkeyring_V2_PushRegistration()
        registration.deviceKeyID = try Sealing.keyID(keys.signingPublicKey())
        registration.apnsToken = token
        registration.apnsTopic = topic
        registration.apnsProduction = production
        registration.noticePublicKey = try keys.noticePublicKey()
        _ = try await relay().call(Self.method { $0.registerPush = registration })
        pushRegistered = true
        if firstRun == .practiceWaiting(arrived: false), practiceTask == nil { askForPractice() }
    }

    // MARK: For the notification service extension

    /// Whether a request arriving now may break through a Focus, from the iPhone's Settings.
    nonisolated public static func breaksThroughFocus(_ shared: PhoneSharedContext) -> Bool {
        (shared.read()?.settings ?? NotificationSettings()).breaksThroughFocus()
    }

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
        let outcome = work.hasOutcome ? state(work.outcome, now: Int64(Date().timeIntervalSince1970), members: members)
            : .waitingForYou(until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
        // This iPhone's practice request: no machine and no password, the board's words.
        if request.forDeviceKeyID == keyID {
            var practice = practiceRequest(request)
            practice.state = outcome
            return (practice, nil)
        }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { return fail("unknown machine") }
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }) else { return fail("login not in the saved catalogue") }
        return (AccessRequest(id: request.requestID, login: RequestedLogin(site: site(login), account: login.account),
                              agent: RequestingAgent(name: request.agent, machine: machine.label, address: "",
                                                     project: request.project.isEmpty ? nil : request.project),
                              access: .login, agentReason: request.reason,
                              askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)), state: outcome),
                work.hasOutcome ? members.devices.first { $0.label == work.outcome.answeredBy }.flatMap { shortName($0.kind) } : nil)
    }

    // MARK: Saving

    private var stateURL: URL { directory.appending(path: "phone-v2.plist") }

    private func save(_ next: PhoneSavedState) {
        let sharedChanged = next.members != state.members || next.catalogue != state.catalogue || next.deviceKeyID != state.deviceKeyID
            || next.settings != state.settings
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
