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
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

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
    /// Where first run stands once joined; nil reads as its first step after joining. A step an
    /// earlier build saved that this build no longer has also reads as nil, never as a broken state.
    @Lenient var firstRun: PhoneFirstRun?
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
    /// Apple Watch's practice request has been sent: it is not sent again.
    var watchPracticed: Bool?
    /// SHA-256 of the push address registered with the relay: a locked iPhone's arrival note names it.
    var pushTokenSHA256: Data?
}

/// A saved value that reads as nil when its form has changed, so the rest of the saved state still reads.
@propertyWrapper
struct Lenient<Value: Codable>: Codable {
    var wrappedValue: Value?
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try? Value(from: decoder) }
    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}

extension KeyedDecodingContainer {
    func decode<Value>(_ type: Lenient<Value>.Type, forKey key: Key) throws -> Lenient<Value> {
        try decodeIfPresent(type, forKey: key) ?? Lenient(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    mutating func encode<Value>(_ value: Lenient<Value>, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}

/// What the notification service extension needs to name a request: this
/// iPhone's key id, the Members and the Catalogue; and to tell the relay it
/// arrived: the relay's address and the push address's hash. Kept in the keychain group
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
        shared.endpoint = state.endpoint; shared.pushTokenSHA256 = state.pushTokenSHA256
        guard let data = try? PropertyListEncoder().encode(shared) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Forgets what the extension was handed: the keychain keeps it when the app is removed.
    public func delete() { SecItemDelete(query as CFDictionary) }

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
        firstRun = (state.firstRun ?? (state.deviceKeyID == nil ? .start : .notifications)).restored
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
            snapshot.notificationFacts = facts
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
        let macLabels = Set(members.devices.filter { $0.kind == .mac }.map(\.label))
        let devices = members.devices.map { device in
            PhoneDevice(id: device.keyID, name: device.label, detail: Self.howItApproves(device.kind), role: .approves,
                        isThisIPhone: device.keyID == mine, canPractice: device.keyID != mine, canRemove: device.keyID != mine)
        } + members.machines.map { machine in
            // The computer that stays on passes requests to this iPhone. A Mac is removed from its row above, both at once.
            let passes = machine.machineID == members.relayMachineID ? PhoneCopy.passesRequests : nil
            return PhoneDevice(id: machine.machineID, name: machine.label, detail: passes, role: .asks, canRemove: !macLabels.contains(machine.label))
        }
        let pendingWatch = state.watchDevice.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
        var snapshot = PhoneSnapshot(firstRun: firstRun, requests: requests, logins: logins, devices: devices)
        snapshot.joined = true
        snapshot.practiceRequest = practiceOpen
        snapshot.relayName = members.machines.first { $0.machineID == members.relayMachineID }?.label
        snapshot.watch = watchFacts(members)
        snapshot.notices = notices(members: members, pendingWatch: pendingWatch)
        snapshot.settings = phoneSettings
        snapshot.notificationFacts = facts
        snapshot.journey = journey
        // Blocked passwords have no copies anywhere, so they are not waited for.
        let copies = catalogue?.logins.filter { $0.rule != .blocked }.count ?? 0
        if let sealedForYou, sealedForYou < copies { snapshot.filling = PhoneFill(copied: sealedForYou, of: copies) }
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
        let previous = firstRun
        PhoneDiagnostics.log.note("firstrun", "moved", ["from": "\(firstRun)", "to": "\(next)", "by": "\(event)"])
        firstRun = next
        var saved = state
        saved.firstRun = next
        save(saved)
        if next == .lookingForMac { lookForMac() }
        // The other devices follow this iPhone's step from its status report.
        if next.journeyStep != previous.journeyStep { Task { await reportSelfTest() } }
        // A new practice request: the 30-second timer starts, and it is asked for once Apple has given a push address.
        if case let .practiceWaiting(id, false) = next, previous.practiceID != id { beginPractice(id) }
        if case let .settingUpNotifications(id) = next, practiceTask == nil { askForPractice(id) }
    }

    /// A tap on a first-run screen, or what iOS answered about notifications.
    public func firstRun(_ event: PhoneFirstRun.Event) async {
        if event == .askAgain { failedJoin = nil }
        apply(event)
    }

    /// The practice request while it is open: on its own before joining, the relay's after.
    private var practiceOpen: AccessRequest? {
        switch firstRun {
        case .welcome(practising: true): .practice()
        case let .practice(id): practiceWork(id).flatMap { work in (try? Sealing.parseRequest(work.request)).map(Self.practiceRequest) }
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

    /// This iPhone's practice request with this id, as this iPhone last heard of it.
    private func practiceWork(_ id: String) -> Work? {
        state.work[id].flatMap { try? Work(serializedBytes: $0) }.flatMap { isPracticeWork($0) ? $0 : nil }
    }

    /// The practice request for this iPhone still waiting for an answer, if any: one at most.
    private var waitingPractice: Work? {
        let now = Int64(Date().timeIntervalSince1970)
        return state.work.values.compactMap { try? Work(serializedBytes: $0) }.first { work in
            !work.hasOutcome && isPracticeWork(work) && ((try? Sealing.parseRequest(work.request))?.answerByUnixSeconds ?? 0) > now
        }
    }

    private func isPracticeWork(_ work: Work) -> Bool {
        guard let mine = state.deviceKeyID else { return false }
        return (try? Sealing.parseRequest(work.request))?.forDeviceKeyID == mine
    }

    /// What WatchConnectivity says: an Apple Watch is paired, and Agent Keyring's Watch app is on it.
    public func watchPairing(paired: Bool, installed: Bool) {
        guard (paired, installed) != (watchPaired, watchInstalled) else { return }
        watchPaired = paired; watchInstalled = installed
        PhoneDiagnostics.log.note("watch", "pairing", ["paired": "\(paired)", "installed": "\(installed)"])
        publish()
        Task { await reportSelfTest() }
    }
    private var watchPaired = false
    private var watchInstalled = false

    /// The Apple Watch's facts, from WatchConnectivity, its hand-over and self-test, and the list of devices.
    private func watchFacts(_ members: Members) -> PhoneWatchFacts {
        let test = state.watchSelfTest.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        var facts = PhoneWatchFacts()
        facts.paired = watchPaired
        facts.installed = watchInstalled
        facts.added = members.devices.contains { $0.kind == .watch }
        facts.opened = facts.added || state.watchDevice != nil || state.watchSelfTest != nil
        facts.notificationsAllowed = test["notificationsAllowed"] as? Bool == true
        facts.pushAddress = test["pushAddress"] as? Bool == true
        facts.practiceAnswered = test["practiceAnswered"] as? Bool == true
        return facts
    }
    /// Set while the work stream cannot reach the relay.
    private var connectionFailed: Error? { didSet { publish() } }

    private func accessRequest(_ work: Work, _ members: Members, _ catalogue: Catalogue?) -> AccessRequest? {
        guard let request = try? Sealing.parseRequest(work.request) else { return nil }
        // A practice request sent from Home or Devices: answered like any other, with the practice words.
        if isPracticeWork(work) {
            var practice = Self.practiceRequest(request)
            let now = Int64(Date().timeIntervalSince1970)
            if work.hasOutcome { practice.state = Self.state(work.outcome, now: now, members: members) }
            else if request.answerByUnixSeconds <= now { practice.state = .unanswered }
            return practice
        }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { return nil }
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
        case .iphone: PhoneCopy.answersWithFaceID
        case .watch: PhoneCopy.answersWithTap
        case .mac: PhoneCopy.answersWithTouchID
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
        guard state.deviceKeyID != nil else { if firstRun.mayJoin { lookForMac() }; return }
        // Back in the app: the practice request first run is on is rejoined by its id, never made again.
        if let id = firstRun.practiceID, practiceTask == nil {
            if firstRun == .practiceWaiting(id: id, arrived: false), practiceTimer == nil { beginPractice(id) } else { askForPractice(id) }
        }
        guard following == nil, state.endpoint != nil else { return }
        uploading = Task { [weak self] in
            while !Task.isCancelled {
                await self?.uploadLog()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
        following = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.refreshMembersAndCatalogue()
                    await self.recheckWaiting()
                    for try await response in try self.relay().stream(Self.method { $0.watchWork = .init() }) {
                        switch response.result {
                        case let .work(work)?: self.receive(work)
                        case let .changes(changes)?: await self.follow(changes)
                        default: break
                        }
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
        uploading?.cancel(); uploading = nil
        Task { await uploadLog() }
        looking?.cancel(); looking = nil
    }

    func receive(_ work: Work, refreshed: Bool = false) {
        guard let request = try? Sealing.parseRequest(work.request) else { return }
        // Only a request the computer it names signed: the relay can't make one up or pass one off as another's.
        let signed: Bool = {
            guard let trusted = members, let ownKeyID = try? Sealing.keyID(keys.signingPublicKey()) else { return false }
            do { try Sealing.checkRequest(work, members: trusted, ownKeyID: ownKeyID); return true } catch { return false }
        }()
        guard signed else {
            // A computer added since this iPhone last looked: fetch the lists, then check again once.
            if !refreshed, members?.machines.contains(where: { $0.machineID == request.machineID }) != true {
                Task { try? await refreshMembersAndCatalogue(); receive(work, refreshed: true) }
            }
            return
        }
        // The relay writes a request once; a later Work for it may only add the outcome.
        let saved = state.work[request.requestID].flatMap { try? Work(serializedBytes: $0) }
        if let saved, saved.request != work.request { return }
        if saved == nil, !work.hasOutcome { Task { await reportArrival(request.requestID) } }
        var next = state
        next.work[request.requestID] = try? work.serializedData()
        if work.hasOutcome { next.answered[request.requestID] = nil; PhoneNotifications.remove(request.requestID) }
        save(next)
        // The practice request reaches first run here too, so its end is seen even if its own stream was lost.
        if isPracticeWork(work) {
            // Only first run's own practice request moves first run; one sent from Home is answered like any request.
            guard request.requestID == firstRun.practiceID else { return }
            if work.hasOutcome { practiceOutcome = Self.latched(practiceOutcome, work.outcome.state); apply(.practiceEnded(Self.outcome(work.outcome.state))) }
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

    /// Tells the relay a request has reached this iPhone, so the Mac can say where it is. Sent the first
    /// time the app holds the request; the reply key needs the iPhone unlocked.
    private func reportArrival(_ requestID: String) async {
        guard let keyID = state.deviceKeyID else { return }
        var arrival = Agentkeyring_V2_Arrival()
        arrival.domain = "agentkeyring.arrival.v2"
        arrival.requestID = requestID
        arrival.deviceKeyID = keyID
        arrival.arrivedUnixSeconds = Int64(Date().timeIntervalSince1970)
        do {
            let signed = try Sealing.signed(arrival.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
            _ = try await relay().call(Self.method { $0.arrived = signed })
            PhoneDiagnostics.log.note("request", "arrival sent", ["request": requestID])
        } catch {
            PhoneDiagnostics.log.note("request", "arrival not sent", ["request": requestID, "error": "\(error)"])
        }
    }

    /// What changed at the relay. A new status report: read where the other devices are.
    private func follow(_ changes: Agentkeyring_V2_Changes) async {
        if Int(changes.sealedForYou) != sealedForYou { sealedForYou = Int(changes.sealedForYou); publish() }
        guard changes.reportsRevision != reportsRevision else { return }
        reportsRevision = changes.reportsRevision
        guard let members, case let .selfTests(tests)? = try? await relay().call(Self.method { $0.selfTests = .init() }).result else { return }
        var next = PhoneJourney()
        for document in tests.reports {
            guard let signer = try? Sealing.verify(document, members: members, allowReplyKey: true),
                  let report = try? Agentkeyring_V2_SelfTestReport(serializedBytes: document.payload),
                  report.deviceKeyID == signer.keyID, signer.keyID != state.deviceKeyID else { continue }
            let place = PhoneJourney.Place(device: signer.label, step: Self.step(report.step), finished: report.finished)
            if signer.kind == .mac, next.mac == nil {
                next.mac = place
                next.steps = report.journey.compactMap(Self.step)
            } else {
                next.others.append(place)
            }
        }
        if next != journey {
            PhoneDiagnostics.log.note("journey", "read", ["steps": next.steps.map(\.rawValue).joined(separator: ","),
                "mac": next.mac.map { "\($0.step?.rawValue ?? "none") finished=\($0.finished)" } ?? "none"])
            journey = next
            publish()
        }
    }
    private var reportsRevision: UInt64?
    private var sealedForYou: Int?
    private var journey = PhoneJourney()

    nonisolated static func step(_ step: Agentkeyring_V2_JourneyStep) -> PhoneJourney.Step? {
        switch step {
        case .welcome: .welcome
        case .chooseDevices: .chooseDevices
        case .practice: .practice
        case .passwords: .passwords
        case .agents: .agents
        case .alwaysOn: .alwaysOn
        case .iphone: .iPhone
        case .watch: .watch
        case .computers: .computers
        case .tryDevices: .tryDevices
        case .ready: .ready
        default: nil
        }
    }

    nonisolated static func step(_ step: PhoneJourney.Step) -> Agentkeyring_V2_JourneyStep {
        switch step {
        case .welcome: .welcome
        case .chooseDevices: .chooseDevices
        case .practice: .practice
        case .passwords: .passwords
        case .agents: .agents
        case .alwaysOn: .alwaysOn
        case .iPhone: .iphone
        case .watch: .watch
        case .computers: .computers
        case .tryDevices: .tryDevices
        case .ready: .ready
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
            return
        }
        var next = state
        next.members = try signed.serializedData()
        save(next)
    }

    func accept(catalogue signed: SignedDocument) throws {
        guard let members else { return }
        if let current = state.catalogue, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return }
        let verified = try Sealing.verifiedCatalogue(signed, members: members, current: catalogue)
        var next = state
        next.catalogue = try signed.serializedData()
        // A Blocked password keeps no copy here either: the requests this iPhone saved drop theirs.
        let blocked = Set(verified.logins.filter { $0.rule == .blocked }.map(\.loginID))
        for (id, bytes) in next.work {
            guard var work = try? Work(serializedBytes: bytes), work.hasSealedLogin,
                  blocked.contains(work.sealedLogin.loginID) else { continue }
            work.clearSealedLogin()
            next.work[id] = try? work.serializedData()
        }
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
        if firstRun == .welcome(practising: true), requestID == AccessRequest.localPracticeID {
            let context = LAContext()
            defer { context.invalidate() }
            try await keys.authorize(context, reason: PhoneCopy.faceIDPractice)
            return apply(.closePractice)
        }
        if let work = practiceWork(requestID) { return try await approveTest(work) }
        // The notification's Approve and the app's can both run for one request: the second is not an error.
        if settled(requestID) { return PhoneNotifications.remove(requestID) }
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
        // The relay is not trusted to say who asked: the machine named signed the request.
        try Sealing.checkRequest(work, members: members, ownKeyID: Sealing.keyID(keys.signingPublicKey()))
        try await keys.authorize(context, reason: PhoneCopy.faceIDApprove(agent: request.agent, computer: machine.label, site: Self.site(login)))
        // The relay is not trusted to say which copy is which: a device signed it, it is the current version, and it was sealed as this login.
        try Sealing.checkSealed(work.sealedLogin, members: members, listed: login)
        let secret = try keys.open(work.sealedLogin, context: context)
        try Sealing.checkBound(secret, title: login.title, sites: login.sites, account: login.account)
        let upload = try Sealing.approve(
            request: work.request, secret: secret, sites: login.sites,
            receivingKey: P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey),
            signerKeyID: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        try await send(upload, for: requestID, approving: true)
    }

    public func deny(_ requestID: String, reply: String?) async throws {
        if firstRun == .welcome(practising: true), requestID == AccessRequest.localPracticeID { return apply(.closePractice) }
        if practiceWork(requestID) != nil { return await denyTest(requestID) }
        if settled(requestID) { return PhoneNotifications.remove(requestID) }
        let work = try await currentWork(requestID)
        let upload: AnswerUpload
        if let reply, !reply.isEmpty {
            upload = try Sealing.deny(request: work.request, reply: reply, signerKeyID: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        } else {
            upload = Sealing.plainDeny(requestID: requestID)
        }
        try await send(upload, for: requestID, approving: false)
    }

    /// This iPhone has answered the request, or it has ended.
    func settled(_ requestID: String) -> Bool {
        state.answered[requestID] != nil || state.work[requestID].flatMap { try? Work(serializedBytes: $0) }?.hasOutcome == true
    }

    private func send(_ upload: AnswerUpload, for requestID: String, approving: Bool) async throws {
        var next = state
        next.answered[requestID] = approving
        save(next)
        do {
            _ = try await relay().call(Self.method { $0.answer = upload })
            PhoneDiagnostics.note("Answer sent to the relay: \(approving ? "approve" : upload.denyRequestID.isEmpty ? "deny with words" : "deny")")
            PhoneNotifications.remove(requestID)
        } catch {
            // The relay may have recorded it before the reply was lost, or taken the same answer from this iPhone already.
            if case let .work(work)? = try? await relay().call(Self.method { $0.getWork.requestID = requestID }).result,
               work.hasOutcome, work.outcome.state == (approving ? .approved : .denied) {
                PhoneDiagnostics.note("Answer already recorded by the relay: \(work.outcome.state)")
                receive(work)
                return
            }
            PhoneDiagnostics.note("Answer not sent: \(error)")
            Task { await uploadLog() }
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
        let change: (loginID: String, rule: Agentkeyring_V2_Rule) = switch rule {
        case .ask: (loginID, .ask)
        case .automatic: (loginID, .automatic)
        case .blocked: (loginID, .blocked)
        }
        guard change.rule != old.rule else { return }
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
    /// machine allowed Automatic logins; leaving Automatic withdraws those copies.
    /// Each Login keeps its version, and each copy the version of the one opened.
    private func publish(_ changes: [(loginID: String, rule: Agentkeyring_V2_Rule)], context: LAContext) async throws {
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
            if login.rule == .automatic && old.rule != .automatic {
                if mine.isEmpty, case let .sealedLogins(held) = try await relay.call(Self.method { $0.sealedLogins = .init() }).result {
                    mine = Dictionary(held.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
                }
                guard let sealed = mine[change.loginID] else {
                    throw KeyringRelayError(code: .notFound, message: "This iPhone holds no copy of that login.")
                }
                try Sealing.checkSealed(sealed, members: members, listed: old)
                let secret = try keys.open(sealed, context: context)
                for machine in members.machines where machine.automaticAllowed {
                    batch.logins.append(try Sealing.seal(secret, version: sealed.version,
                        to: P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey), openerID: machine.machineID, signer: sealSigner))
                }
            }
            // Leaving Automatic, or becoming Blocked: no computer keeps a copy. The relay also deletes
            // every device's copy of a password the new catalogue sets to Blocked.
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







    /// Removes a device or machine: the next Members, signed after Face ID.
    public func remove(device deviceID: String) async throws {
        guard var next = members else { return }
        let context = LAContext()
        defer { context.invalidate() }
        let name = next.devices.first { $0.keyID == deviceID }?.label ?? next.machines.first { $0.machineID == deviceID }?.label ?? ""
        try await keys.authorize(context, reason: PhoneCopy.faceIDRemove(name))
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

    /// What this iPhone signs its sealed copies with: its reply key, which needs no Face ID.
    private var sealSigner: Sealing.Signer {
        Sealing.Signer(keyID: (try? Sealing.keyID(keys.replyPublicKey())) ?? "", sign: keys.signReply)
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
        guard looking == nil, state.deviceKeyID == nil, firstRun.mayJoin else { return }
        if lookingSince == nil { lookingSince = Date() }
        looking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state.deviceKeyID == nil else { break }
                let link = self.linkInvitation ?? self.invitation()
                // The Mac names itself before any computer that stays on exists: an invitation with no relay.
                if let invite = link.flatMap(Self.invite), invite.relayHost.isEmpty, invite.secret.isEmpty {
                    self.apply(.macWithoutComputer(mac: invite.inviterLabel.isEmpty ? nil : invite.inviterLabel))
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                if self.firstRun.mayJoin, let link,
                   self.failedJoin.map({ $0.link != link || Date().timeIntervalSince($0.at) > 30 }) ?? true {
                    do { try await self.joinNow(link) } catch {
                        // Leaving the app cuts the connection: the request stays waiting at the relay and
                        // is picked up, by asking again with the same keys, when he comes back.
                        if Task.isCancelled { break }
                        self.failedJoin = (link, Date())
                        PhoneDiagnostics.log.note("join", "not joined", ["error": "\(error)"])
                    }
                }
                if self.state.deviceKeyID != nil || Task.isCancelled { break }
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

    /// The `JoinInvite` in an `agentkeyring://join?invite=<base64url>` link.
    nonisolated static func invite(_ link: String) -> Agentkeyring_V2_JoinInvite? {
        guard let url = URLComponents(string: link), url.scheme == "agentkeyring", url.host == "join",
              let encoded = url.queryItems?.first(where: { $0.name == "invite" })?.value,
              let bytes = Data(base64URL: encoded) else { return nil }
        return try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes)
    }

    /// Joins with an invitation link: `agentkeyring://join?invite=<JoinInvite, base64url>`.
    private func joinNow(_ link: String) async throws {
        guard let invite = Self.invite(link), !invite.relayHost.isEmpty, invite.relayPort > 0, invite.relayPort <= UInt32(UInt16.max) else {
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
            case .waiting: apply(.joinWaiting(mac: invite.inviterLabel.isEmpty ? nil : invite.inviterLabel))
            case .refused:
                apply(.joinRefused(mac: invite.inviterLabel.isEmpty ? nil : invite.inviterLabel))
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

    /// What iOS allows, as the app last read it: for the checklist, the self-test, and whether a practice push will come.
    private var facts = PhoneNotificationFacts() { didSet { publish() } }
    private var notificationsAllowed: Bool { facts.allowed }

    public func notificationFacts(_ next: PhoneNotificationFacts) async {
        guard next != facts else { return }
        facts = next
        Task { await reportSelfTest() }
        PhoneDiagnostics.log.note("notifications", "read", ["allowed": "\(next.allowed)", "banners": "\(next.banners)",
            "lockScreen": "\(next.lockScreen)", "timeSensitive": "\(next.timeSensitive)", "scheduledSummary": "\(next.inScheduledSummary)"])
    }

    /// The relay has this launch's push address. The practice request waits for
    /// it, so that its push can show that requests reach this iPhone.
    private var pushRegistered = false { didSet { publish() } }

    /// How the last practice request ended, for the self-test report.
    private var practiceOutcome: Agentkeyring_V2_LeaseState?

    nonisolated static func outcome(_ state: Agentkeyring_V2_LeaseState) -> PhonePracticeOutcome {
        switch state {
        case .approved, .ended: .approved
        case .denied: .denied
        default: .noAnswer
        }
    }

    /// An approved practice stays approved: a minute later its approval ends, which is not a failure.
    nonisolated static func latched(_ old: Agentkeyring_V2_LeaseState?, _ new: Agentkeyring_V2_LeaseState) -> Agentkeyring_V2_LeaseState {
        old == .approved ? .approved : new
    }

    /// First run waits for the practice request: 30 seconds, then the screen says why it hasn't come.
    private func beginPractice(_ id: String) {
        practiceTimer?.cancel()
        practiceTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            self.practiceTimer = nil
            self.apply(.practiceTimedOut(pushAddress: self.pushRegistered))
        }
        if pushRegistered { askForPractice(id) }
    }

    private var practiceTimer: Task<Void, Never>?
    private var practiceTask: Task<Void, Never>?
    /// Which ask is the current one, so that a replaced ask cannot clear its successor.
    private var practiceAsk = 0

    /// Asks the relay for one practice request for this iPhone: it arrives pushed, like any request, which
    /// shows that requests reach the phone. The relay's first reply names the request, and first run keeps
    /// that id, so a return to the app shows the same request. A dropped connection is not a failure: the
    /// request stays at the relay, and its end also comes on the work stream.
    private func askForPractice(_ id: String) {
        practiceTask?.cancel()
        practiceAsk += 1
        let ask = practiceAsk
        practiceTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await response in try self.relay().stream(Self.method { $0.testRequest.requestID = id }) {
                    guard case let .lease(lease) = response.result else { continue }
                    if lease.state == .waiting {
                        PhoneDiagnostics.log.note("practice", "made", ["request": lease.requestID])
                        self.apply(.practiceSent(id: lease.requestID))
                        // The request may have come on the work stream before the relay's reply.
                        if self.practiceWork(lease.requestID) != nil {
                            self.apply(.practiceArrived(pushExpected: self.notificationsAllowed && self.pushRegistered))
                        }
                        continue
                    }
                    self.practiceOutcome = Self.latched(self.practiceOutcome, lease.state)
                    self.apply(.practiceEnded(Self.outcome(lease.state)))
                    await self.reportSelfTest()
                }
            } catch { PhoneDiagnostics.log.note("practice", "stream ended", ["error": "\(error)"]) }
            if self.practiceAsk == ask { self.practiceTask = nil }
        }
    }

    /// A tap on a notification: the practice request opens over first run.
    public func notificationOpened(_ requestID: String) {
        PhoneDiagnostics.log.note("notification", "opened", ["request": requestID])
        if requestID == firstRun.practiceID { return apply(.practiceTapped) }
        // Opened from the Lock Screen while the app was away: its stream has not sent the request yet, so ask for it.
        guard state.work[requestID] == nil, state.endpoint != nil else { return }
        Task {
            guard case let .work(work)? = try? await relay().call(Self.method { $0.getWork.requestID = requestID }).result else { return }
            receive(work)
            if requestID == firstRun.practiceID { apply(.practiceTapped) }
        }
    }

    func denyTest(_ id: String) async {
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
    func approveTest(_ work: Work) async throws {
        let context = LAContext()
        defer { context.invalidate() }
        try await keys.authorize(context, reason: PhoneCopy.faceIDPractice)
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

    /// The recent log, Apple Watch's lines with it, signed with the reply key, for the relay to keep:
    /// `agent-keyring logs` on the Mac reads it back. Sent on leaving the screen, every 5 minutes while
    /// open, and after an answer fails.
    public func uploadLog() async {
        guard let keyID = state.deviceKeyID, state.endpoint != nil else { return }
        PhoneDiagnostics.log.collect()
        var log = Agentkeyring_V2_DeviceLog()
        log.domain = "agentkeyring.log.v2"
        log.deviceKeyID = keyID
        log.lines = PhoneDiagnostics.log.lines()
        let background = PhoneBackgroundTime.begin("Log upload")
        defer { PhoneBackgroundTime.end(background) }
        do {
            let signed = try Sealing.signed(log.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
            _ = try await relay().call(Self.method { $0.reportLog = signed })
        } catch { logger.error("Log not uploaded: \(String(describing: error), privacy: .public)") }
    }

    private var uploading: Task<Void, Never>?

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
        report.step = Self.step(firstRun.journeyStep)
        report.finished = firstRun == .finished
        // The checklist first, by the names every device uses, then what only the logs need.
        report.checks = [
            check("linked", true),
            check("notifications", facts.allowed, "notifications are off"),
            check("time_sensitive", facts.timeSensitive, "Time Sensitive is off"),
            check("practice", practiceOutcome == .approved, practiceOutcome.map { "ended \($0)" } ?? "not answered"),
            check("push address", pushRegistered, "not registered with the relay"),
            check("push reached this iPhone", state.pushSeen, "no push has arrived"),
            check("opening key", openingWorks ?? false, openingWorks == nil ? "no sealed login to open" : "did not open"),
        ]
        // Apple Watch reports through this iPhone: its step is the iPhone's Watch step.
        if let members, watchPaired || members.devices.contains(where: { $0.kind == .watch }) {
            let watch = watchFacts(members)
            report.checks += [
                check("watch installed", watch.installed, "the Watch app is not on Apple Watch"),
                check("watch opened", watch.opened, "the Watch app has not been opened"),
                check("watch added", watch.added, "not in the list of devices"),
                check("watch notifications", watch.notificationsAllowed, "notifications are off on Apple Watch"),
                check("watch push_address", watch.pushAddress, "Apple has not given Apple Watch a push address"),
                check("watch practice", watch.practiceAnswered, "not answered"),
            ]
            let test = state.watchSelfTest.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            if let problem = test?["problem"] as? String, !problem.isEmpty { report.checks.append(check("watch problem", false, problem)) }
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
        askForWatchPractice()
    }

    /// Apple Watch's own practice request (Paper, "First run", Apple Watch row), once it is
    /// added and its self-test says a push can reach it. The relay sends it to the Watch only.
    /// Apple Watch's own practice request once it is added and its self-test says a push can reach it, sent once.
    private func askForWatchPractice() {
        guard state.watchPracticed != true, watchPracticeTask == nil,
              let watch = members?.devices.first(where: { $0.kind == .watch }),
              let data = state.watchSelfTest,
              let test = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              test["notificationsAllowed"] as? Bool == true, test["pushAddress"] as? Bool == true else { return }
        watchPracticeTask = Task { [weak self] in
            guard let self else { return }
            if await self.askRelayForPractice(for: watch.keyID) {
                var done = self.state
                done.watchPracticed = true
                self.save(done)
            }
            self.watchPracticeTask = nil
        }
    }

    private var watchPracticeTask: Task<Void, Never>?

    /// Practice on Home (this iPhone) or on a row in Devices (another device).
    /// Practice on Home (this iPhone) or on a row in Devices (another device). For this iPhone, the one
    /// already waiting is returned to be shown again instead of a second being made.
    public func sendPractice(to deviceID: String?) async -> String? {
        guard let deviceID, deviceID != state.deviceKeyID else {
            if let waiting = waitingPractice, let id = try? Sealing.parseRequest(waiting.request).requestID { return id }
            askForPractice(PhoneFirstRun.newPracticeID())
            return nil
        }
        _ = await askRelayForPractice(for: deviceID)
        return nil
    }

    /// Asks the relay to make a practice request for another device. True once the relay has made and pushed it:
    /// that is all the iPhone waits for, with time asked of iOS so that leaving the app at once does not cut it short.
    private func askRelayForPractice(for deviceID: String) async -> Bool {
        let background = PhoneBackgroundTime.begin("A practice request")
        defer { PhoneBackgroundTime.end(background) }
        do {
            for try await response in try relay().stream(Self.method { $0.testRequest.forDeviceKeyID = deviceID }) {
                guard case .lease = response.result else { continue }
                PhoneDiagnostics.log.note("practice", "sent", ["device": String(deviceID.prefix(16))])
                return true
            }
        } catch { PhoneDiagnostics.log.note("practice", "not sent", ["device": String(deviceID.prefix(16)), "error": "\(error)"]) }
        return false
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
        try await keys.authorize(context, reason: PhoneCopy.faceIDAddWatch)
        let relay = try relay()
        guard case let .sealedLogins(mine) = try await relay.call(Self.method { $0.sealedLogins = .init() }).result else {
            throw KeyringRelayError(code: .unavailable, message: "The relay sent no sealed logins.")
        }
        var forWatch = Agentkeyring_V2_SealedLogins()
        let current = members
        forWatch.logins = try mine.logins.compactMap { copy in
            guard let current, let listed = catalogue?.logins.first(where: { $0.loginID == copy.loginID }) else { return nil }
            try Sealing.checkSealed(copy, members: current, listed: listed)
            return try Sealing.seal(keys.open(copy, context: context), version: copy.version, to: watchKey, openerID: watch.keyID, signer: sealSigner)
        }
        next.revision += 1
        next.devices.append(watch)
        let signed = try Sealing.signed(next.serializedData(), by: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        _ = try await relay.call(Self.method { $0.publishMembers = signed })
        try accept(members: signed)
        _ = try await relay.call(Self.method { $0.publishSealedLogins = forWatch })
        PhoneDiagnostics.note("Watch added: \(forWatch.logins.count) logins sealed to it")
        apply(.watchDone)
        var done = state
        done.watchDevice = nil
        save(done)
        if let push = state.watchPush { await registerWatchPush(push) }
        askForWatchPractice()
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
        let hash = Sealing.sha256(token)
        if state.pushTokenSHA256 != hash { var next = state; next.pushTokenSHA256 = hash; save(next) }
        if case let .practiceWaiting(id, false) = firstRun, practiceTask == nil { askForPractice(id) }
    }

    // MARK: For the notification service extension

    /// Whether a request arriving now may break through a Focus, from the iPhone's Settings.
    /// Tells the relay a request has reached this iPhone, from the notification extension. The phone
    /// may be locked, so it signs nothing: the note names the push address instead, and grants nothing.
    /// It gives up after two seconds: the notification waits for it.
    nonisolated public static func noteArrival(_ requestID: String, shared: PhoneSharedContext) async throws {
        guard let saved = shared.read(), let keyID = saved.deviceKeyID, let endpoint = saved.endpoint,
              let hash = saved.pushTokenSHA256,
              let pinned = saved.members.flatMap({ try? SignedDocument(serializedBytes: $0) })
                  .flatMap({ try? Members(serializedBytes: $0.payload) })?.relayTlsPublicKey
        else { throw KeyringRelayError(code: .unavailable, message: "This iPhone has not joined yet.") }
        var arrival = Agentkeyring_V2_Arrival()
        arrival.domain = "agentkeyring.arrival.v2"
        arrival.requestID = requestID
        arrival.deviceKeyID = keyID
        arrival.arrivedUnixSeconds = Int64(Date().timeIntervalSince1970)
        arrival.pushTokenSha256 = hash
        var note = SignedDocument()
        note.payload = try arrival.serializedData()
        _ = try await RelayHTTPS.post(note.serializedData(), host: endpoint.host, port: endpoint.port, path: "/v2/arrived", pinned: pinned, timeout: 2)
    }

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
        do { return try named(work, members: members, catalogue: catalogue, keyID: keyID) }
        catch { return fail("\(error)") }
    }

    public struct Unnamed: Error, CustomStringConvertible {
        public let description: String
    }

    /// An opened notice's request, named from the signed Members and Catalogue
    /// only: this iPhone's own practice request, or one the computer it names signed.
    nonisolated static func named(_ work: Work, members: Members, catalogue: Catalogue?, keyID: String) throws -> (request: AccessRequest, answeredBy: String?) {
        guard let request = try? Sealing.parseRequest(work.request) else { throw Unnamed(description: "the request did not parse") }
        let outcome = work.hasOutcome ? state(work.outcome, now: Int64(Date().timeIntervalSince1970), members: members)
            : .waitingForYou(until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
        // checkRequest returns no computer for this device's own practice request, and throws for an unsigned one.
        let signer: Agentkeyring_V2_Machine?
        do { signer = try Sealing.checkRequest(work, members: members, ownKeyID: keyID) }
        catch { throw Unnamed(description: "the request is not signed by the computer it names") }
        guard let machine = signer else {
            var practice = practiceRequest(request)
            practice.state = outcome
            return (practice, nil)
        }
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }) else { throw Unnamed(description: "login not in the saved catalogue") }
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

/// Time asked of iOS to finish one call after the app leaves the screen.
enum PhoneBackgroundTime {
    #if canImport(UIKit)
    @MainActor static func begin(_ name: String) -> UIBackgroundTaskIdentifier { UIApplication.shared.beginBackgroundTask(withName: name) }
    @MainActor static func end(_ task: UIBackgroundTaskIdentifier) { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
    #else
    static func begin(_ name: String) -> Int { 0 }
    static func end(_ task: Int) {}
    #endif
}

/// The notifications this app has shown for a request.
public enum PhoneNotifications {
    /// Removes a request's notification once it is answered or has ended, so none is left behind.
    public static func remove(_ requestID: String) {
        PhoneDiagnostics.log.note("notification", "removed", ["request": requestID])
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        center.getDeliveredNotifications { delivered in
            let same = delivered.filter { $0.request.content.threadIdentifier == requestID }.map(\.request.identifier)
            if !same.isEmpty { center.removeDeliveredNotifications(withIdentifiers: same) }
        }
        #endif
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
