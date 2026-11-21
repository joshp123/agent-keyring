// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt for the direct protocol, with no relay, on 2026.11.21.
//
// The iPhone as an approving device. It joins the Mac directly, keeps the
// signed Members and Catalogue and its own copy of every password from the
// Mac's door, learns of requests from their pushes, and answers at the asking
// computer's door: Approve opens its own copy after Face ID and seals it again
// for the asking computer; Deny with words is signed with the reply key; plain
// Deny is unsigned and grants nothing. Nothing depends on reaching the iPhone:
// it learns only when it dials out, or from a push.

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

@MainActor
public final class PhoneKeyring: PhoneBackend {
    private let directory: URL
    private let shared: PhoneSharedContext
    private let keys: any PhoneDeviceKeys
    private let identity: @MainActor () throws -> RelayTLSIdentity
    private var state = PhoneSavedState()
    private var subscribers: [UUID: AsyncStream<PhoneSnapshot>.Continuation] = [:]
    private let logger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Keyring")

    public init(directory: URL, shared: PhoneSharedContext, keys: any PhoneDeviceKeys,
                identity: @escaping @MainActor () throws -> RelayTLSIdentity) {
        self.directory = directory
        self.shared = shared
        self.keys = keys
        self.identity = identity
        if let data = try? Data(contentsOf: stateURL), let saved = try? PropertyListDecoder().decode(PhoneSavedState.self, from: data) {
            state = saved
        }
        // Joined before the direct protocol (no Mac door saved): that membership went with the relay. The keys stay.
        if state.deviceKeyID != nil, state.mac == nil { state = PhoneSavedState() }
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
        var snapshot = PhoneSnapshot(firstRun: firstRun, practiceRequest: practiceOpen)
        snapshot.settings = phoneSettings
        snapshot.notificationFacts = facts
        snapshot.addWatch = addWatchFlow
        snapshot.macName = state.mac?.name ?? foundMac.flatMap { $0.inviterLabel.isEmpty ? nil : $0.inviterLabel }
        guard let members, state.deviceKeyID != nil else { return snapshot }
        let catalogue = self.catalogue
        snapshot.requests = state.work.values.compactMap { try? Work(serializedBytes: $0) }.compactMap { accessRequest($0, members, catalogue) }
        snapshot.logins = (catalogue?.logins ?? []).map { login in
            PhoneLogin(id: login.loginID, site: Self.site(login), account: login.account, rule: Self.rule(login))
        }
        let mine = state.deviceKeyID
        let macLabels = Set(members.devices.filter { $0.kind == .mac }.map(\.label))
        snapshot.devices = members.devices.map { device in
            PhoneDevice(id: device.keyID, name: device.label, detail: Self.howItApproves(device.kind), role: .approves,
                        isThisIPhone: device.keyID == mine, canPractice: device.keyID != mine && device.kind == .watch,
                        canRemove: device.keyID != mine)
        } + members.machines.map { machine in
            // A Mac is removed from its device row above, both at once.
            PhoneDevice(id: machine.machineID, name: machine.label, role: .asks, canRemove: !macLabels.contains(machine.label))
        }
        snapshot.joined = true
        snapshot.watch = watchFacts(members)
        if macUnreachable { snapshot.notices.append(.macOffline(state.mac?.name)) }
        else if !pushRegistered && !state.pushSeen { snapshot.notices.append(.stillConnecting) }
        snapshot.undelivered = undelivered
        if let copiesExpected, copiesHeld < copiesExpected { snapshot.filling = PhoneFill(copied: copiesHeld, of: copiesExpected) }
        return snapshot
    }

    private func publish() {
        let next = snapshot
        for continuation in subscribers.values { continuation.yield(next) }
    }

    // MARK: First run

    /// Where first run stands: the one state every first-run screen and step follows.
    private(set) var firstRun = PhoneFirstRun.start

    /// Moves first run on by its table, saves it, and starts what the new state asks for.
    private func apply(_ event: PhoneFirstRun.Event) {
        let next = firstRun.on(event)
        guard next != firstRun else { return }
        let previous = firstRun
        PhoneDiagnostics.log.note("firstrun", "moved", ["from": "\(firstRun)", "to": "\(next)", "by": "\(event)"])
        firstRun = next
        var saved = state
        saved.firstRun = next
        save(saved)
        if next.looksForMac { lookForMac() }
        if next.mayJoin, !previous.mayJoin { joinMac() }
        if case .waitingForMac = previous, event == .cancel { Task { await withdrawJoin() } }
        if next == .receivingPasswords { Task { await receivePasswords() } }
        // A new practice request: the 30-second timer starts, and it is asked for once Apple has given a push address.
        if case let .practiceWaiting(id, false) = next, previous.practiceID != id { beginPractice(id) }
        if case let .settingUpNotifications(id) = next, practiceTask == nil { askForPractice(id) }
        if next == .addWatch, addWatchFlow == nil { openAddWatch() }
    }

    /// A tap on a first-run screen, or what iOS answered about notifications.
    public func firstRun(_ event: PhoneFirstRun.Event) async { apply(event) }

    // MARK: Keeping up with the Mac

    /// In front: until joined, look for the Mac; once joined, fetch what changed, pick up requests whose
    /// notifications are on the Lock Screen, and rejoin first run's practice request by its id.
    public func start() {
        guard state.deviceKeyID != nil else {
            if firstRun.looksForMac { lookForMac() }
            if firstRun.mayJoin { joinMac() }
            return
        }
        Task { await refresh() }
        Task { await readDeliveredNotifications() }
        if let id = firstRun.practiceID, practiceTask == nil {
            if firstRun == .practiceWaiting(id: id, arrived: false), practiceTimer == nil { beginPractice(id) } else { askForPractice(id) }
        }
        if firstRun == .receivingPasswords { Task { await receivePasswords() } }
        uploading?.cancel()
        uploading = Task { [weak self] in
            while !Task.isCancelled {
                await self?.uploadLog()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    /// Leaving the screen. A held Face ID confirmation stays until its deadline: iOS may keep the app.
    public func stop() {
        uploading?.cancel(); uploading = nil
        looking?.cancel(); looking = nil
        Task { await uploadLog() }
    }

    private var uploading: Task<Void, Never>?

    /// Fetches the lists and this iPhone's copies from the Mac's door. The Mac's last answer stays if it cannot be reached.
    @discardableResult
    private func refresh() async -> Bool {
        guard let door = state.mac else { return false }
        do {
            // Every revision of the list of devices since the one held, so each checks against the one before.
            let reply = try await macDoor(door).get("/v2/bundle", query: [URLQueryItem(name: "members", value: "\(members?.revision ?? 0)")])
            try accept(bundle: Agentkeyring_V2_Bundle(serializedBytes: reply))
            if macUnreachable { macUnreachable = false; publish() }
            return true
        } catch {
            PhoneDiagnostics.log.note("mac", "bundle not fetched", ["error": "\(error)"])
            if !macUnreachable { macUnreachable = true; publish() }
            return false
        }
    }

    private var macUnreachable = false

    /// Takes a bundle: each part checked on its own, the lists by their signatures, the copies by their signers.
    func accept(bundle: Agentkeyring_V2_Bundle) throws {
        if bundle.membersSince.isEmpty, bundle.hasMembers { try accept(members: bundle.members) }
        for revision in bundle.membersSince where state.deviceKeyID != nil { try accept(members: revision) }
        guard state.deviceKeyID != nil else { return }
        if bundle.hasCatalogue { try accept(catalogue: bundle.catalogue) }
        guard let members, let catalogue else { return }
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = state.deviceKeyID
        var copies = Agentkeyring_V2_SealedLogins()
        copies.logins = bundle.copies.filter { copy in
            guard copy.openerID == mine, let login = listed[copy.loginID], login.rule != .blocked else { return false }
            return (try? Sealing.checkSealed(copy, members: members, listed: login)) != nil
        }
        var next = state
        next.copies = try copies.serializedData()
        save(next)
        copiesHeld = copies.logins.count
        copiesExpected = catalogue.logins.filter { $0.rule != .blocked }.count
    }

    private var copiesHeld = 0
    private var copiesExpected: Int?

    private var ownCopies: [String: SealedLogin] {
        let held = state.copies.flatMap { try? Agentkeyring_V2_SealedLogins(serializedBytes: $0) }?.logins ?? []
        return Dictionary(held.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func accept(members signed: SignedDocument) throws {
        if let current = state.members, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return }
        let verified = try Sealing.verifiedMembers(signed, current: members)
        guard verified.devices.contains(where: { $0.keyID == state.deviceKeyID }) else {
            // This iPhone was removed: forget everything it held, and look for a Mac again.
            save(PhoneSavedState())
            practiceTask?.cancel(); practiceTask = nil
            practiceTimer?.cancel(); practiceTimer = nil
            apply(.removed)
            return
        }
        var next = state
        next.members = try signed.serializedData()
        save(next)
        onListsChanged?()
    }

    func accept(catalogue signed: SignedDocument) throws {
        guard let members else { return }
        if let current = state.catalogue, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return }
        _ = try Sealing.verifiedCatalogue(signed, members: members, current: catalogue)
        var next = state
        next.catalogue = try signed.serializedData()
        save(next)
        onListsChanged?()
    }

    var members: Members? {
        state.members.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Members(serializedBytes: $0.payload) }
    }

    var catalogue: Catalogue? {
        state.catalogue.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Catalogue(serializedBytes: $0.payload) }
    }

    private func macDoor(_ door: MacDoor) throws -> PhoneMacDoor {
        PhoneMacDoor(host: door.host, port: door.port, key: door.key, client: try identity().identity)
    }

    /// The Mac's door, once joined.
    private func mac() throws -> PhoneMacDoor {
        guard let door = state.mac else { throw PhoneMacDoor.Failure.notJoined }
        return try macDoor(door)
    }

    // MARK: Pushes

    /// Any push or notification this app sees: a request's or an outcome's notice, or the Mac's silent
    /// "something changed". The request's work is in the notice; nothing is fetched to learn of it.
    public func received(_ userInfo: [AnyHashable: Any]) async {
        if !state.pushSeen { var next = state; next.pushSeen = true; save(next) }
        if userInfo["rev"] != nil { await refresh() }
        if let work = openNotice(userInfo) { receive(work) }
    }

    /// A tap on a notification, or one of its buttons: the request it is about opens.
    public func notificationOpened(_ requestID: String, _ userInfo: [AnyHashable: Any]) async {
        PhoneDiagnostics.log.note("notification", "opened", ["request": requestID])
        await received(userInfo)
        if requestID == firstRun.practiceID { apply(.practiceTapped) }
    }

    private func openNotice(_ userInfo: [AnyHashable: Any]) -> Work? {
        guard let keyID = state.deviceKeyID, let base64 = userInfo["akr"] as? String, let bytes = Data(base64Encoded: base64),
              let notice = try? Agentkeyring_V2_Notice(serializedBytes: bytes) else { return nil }
        do { return try keys.openNotice(notice, deviceKeyID: keyID) }
        catch { PhoneDiagnostics.log.note("push", "notice did not open", ["error": "\(error)"]); return nil }
    }

    /// Requests whose notifications wait on the Lock Screen or in Notification Centre: the app sees a
    /// request's push only when it is in front or the notification is opened, so it reads them on coming to the front.
    private func readDeliveredNotifications() async {
        #if os(iOS)
        for delivered in await UNUserNotificationCenter.current().deliveredNotifications() {
            if let work = openNotice(delivered.request.content.userInfo) { receive(work) }
        }
        #endif
    }

    func receive(_ work: Work) {
        guard let request = try? Sealing.parseRequest(work.request), let members, let keyID = state.deviceKeyID else { return }
        // Only a request the computer it names signed, answered at its own door.
        guard (try? Sealing.checkRequest(work, members: members, ownKeyID: keyID)) != nil || isPracticeWork(work) else {
            PhoneDiagnostics.log.note("request", "refused", ["request": request.requestID, "reason": "not signed by the computer it names"])
            if members.machines.contains(where: { $0.machineID == request.machineID }) == false { Task { await refresh() } }
            return
        }
        // A request is written once; a later notice for it may only add the outcome.
        let saved = state.work[request.requestID].flatMap { try? Work(serializedBytes: $0) }
        if let saved, saved.request != work.request { return }
        if let saved, saved.hasOutcome, !work.hasOutcome { return }
        if saved == nil, !work.hasOutcome { Task { await reportArrival(request) } }
        var next = state
        next.work[request.requestID] = try? work.serializedData()
        if work.hasOutcome { next.answered[request.requestID] = nil; PhoneNotifications.remove(request.requestID) }
        save(next)
        guard isPracticeWork(work), request.requestID == firstRun.practiceID else {
            // A login this iPhone has not seen yet: the Mac's lists changed since it last looked.
            if !request.loginID.isEmpty, catalogue?.logins.contains(where: { $0.loginID == request.loginID }) != true { Task { await refresh() } }
            return
        }
        if work.hasOutcome {
            practiceOutcome = Self.latched(practiceOutcome, work.outcome.state)
            apply(.practiceEnded(Self.outcome(work.outcome.state)))
        } else {
            apply(.practiceArrived(pushExpected: facts.allowed && pushRegistered))
        }
    }

    /// Tells the asking computer a request has reached this iPhone. Sent the first time the app holds the
    /// request; the reply key needs the iPhone unlocked. The notification extension sends its own, unsigned.
    private func reportArrival(_ request: KeyringRequest) async {
        guard let keyID = state.deviceKeyID, let door = Sealing.answerDoor(request) else { return }
        var arrival = Agentkeyring_V2_Arrival()
        arrival.domain = "agentkeyring.arrival.v2"
        arrival.requestID = request.requestID
        arrival.deviceKeyID = keyID
        arrival.arrivedUnixSeconds = Int64(Date().timeIntervalSince1970)
        do {
            let signed = try Sealing.signed(arrival.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
            try await AnswerDoor.arrived(signed, at: door)
            PhoneDiagnostics.log.note("request", "arrival sent", ["request": request.requestID])
        } catch {
            PhoneDiagnostics.log.note("request", "arrival not sent", ["request": request.requestID, "error": "\(error)"])
        }
    }

    /// Tells the Mac where to wake this iPhone, and the key its notices are sealed to. Signed with the reply key.
    public func registerPush(token: Data, topic: String, production: Bool) async throws {
        var registration = Agentkeyring_V2_PushRegistration()
        registration.deviceKeyID = try Sealing.keyID(keys.signingPublicKey())
        registration.apnsToken = token
        registration.apnsTopic = topic
        registration.apnsProduction = production
        registration.noticePublicKey = try keys.noticePublicKey()
        try await post(registration)
        pushRegistered = true
        let hash = Sealing.sha256(token)
        if state.pushTokenSHA256 != hash { var next = state; next.pushTokenSHA256 = hash; save(next) }
        if case let .practiceWaiting(id, false) = firstRun, practiceTask == nil { askForPractice(id) }
    }

    /// A push registration, this iPhone's or its Watch's, signed with this iPhone's reply key.
    private func post(_ registration: Agentkeyring_V2_PushRegistration) async throws {
        var registration = registration
        registration.domain = "agentkeyring.push.v2"
        registration.registeredUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signed = try Sealing.signed(registration.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        _ = try await mac().post("/v2/push-registration", signed.serializedData())
    }

    /// The Mac has this launch's push address. The practice request waits for it.
    private var pushRegistered = false { didSet { publish() } }

    // MARK: Answers

    public func approve(_ requestID: String, reusingUnlock: Bool) async throws {
        if let work = practiceWork(requestID) { return try await approvePractice(work) }
        // The notification's Approve and the app's can both run for one request: the second is not an error.
        if settled(requestID) { return PhoneNotifications.remove(requestID) }
        let work = try currentWork(requestID)
        let request = try Sealing.parseRequest(work.request)
        guard let members, let machine = try Sealing.checkRequest(work, members: members, ownKeyID: state.deviceKeyID ?? "") else {
            throw PhoneMacDoor.Failure.notAllowed("This iPhone may not approve this request.")
        }
        var copy = try ownCopy(for: request, members: members)
        if copy == nil, await refresh() { copy = try ownCopy(for: request, members: members) }
        guard let (login, sealed) = copy else { throw PhoneMacDoor.Failure.notAllowed(PhoneCopy.passwordNotOnThisIPhone) }
        let context = LAContext()
        defer { context.invalidate() }
        if reusingUnlock { context.touchIDAuthenticationAllowableReuseDuration = 10 }
        try await keys.authorize(context, reason: PhoneCopy.faceIDApprove(agent: request.agent, computer: machine.label, site: Self.site(login)))
        let secret = try keys.open(sealed, context: context)
        try Sealing.checkBound(secret, title: login.title, sites: login.sites, account: login.account)
        let upload = try Sealing.approve(
            request: work.request, secret: secret, sites: login.sites,
            receivingKey: P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey),
            signerKeyID: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        try await send(upload, for: work, approving: true)
    }

    /// The password a request is for, from the signed Catalogue, and this iPhone's copy of it, checked
    /// against the Catalogue. Nil if this iPhone holds no current copy.
    private func ownCopy(for request: KeyringRequest, members: Members) throws -> (Agentkeyring_V2_Login, SealedLogin)? {
        let login = try Sealing.signedLogin(for: request, in: catalogue)
        guard let sealed = ownCopies[request.loginID], (try? Sealing.checkSealed(sealed, members: members, listed: login)) != nil else { return nil }
        return (login, sealed)
    }

    public func deny(_ requestID: String, reply: String?) async throws {
        if let work = practiceWork(requestID), reply?.isEmpty ?? true {
            return try await send(Sealing.plainDeny(requestID: requestID), for: work, approving: false)
        }
        if settled(requestID) { return PhoneNotifications.remove(requestID) }
        let work = try currentWork(requestID)
        let upload: AnswerUpload
        if let reply, !reply.isEmpty {
            upload = try Sealing.deny(request: work.request, reply: reply, signerKeyID: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        } else {
            upload = Sealing.plainDeny(requestID: requestID)
        }
        try await send(upload, for: work, approving: false)
    }

    /// This iPhone has answered the request, or it has ended.
    func settled(_ requestID: String) -> Bool {
        state.answered[requestID] != nil || state.work[requestID].flatMap { try? Work(serializedBytes: $0) }?.hasOutcome == true
    }

    /// The Work for a request, as its push brought it.
    private func currentWork(_ requestID: String) throws -> Work {
        guard let saved = state.work[requestID], let work = try? Work(serializedBytes: saved) else {
            throw PhoneMacDoor.Failure.notAllowed("This request is no longer on this iPhone.")
        }
        return work
    }

    /// Sends an answer to the asking computer's door, retrying while it cannot connect. Its reply is the
    /// request's Lease: this answer's, or the one that already ended it, which is then what is shown.
    private func send(_ upload: AnswerUpload, for work: Work, approving: Bool) async throws {
        let request = try Sealing.parseRequest(work.request)
        let requestID = request.requestID
        guard let door = Sealing.answerDoor(request) else { throw PhoneMacDoor.Failure.notAllowed("The request names no door to answer at.") }
        var next = state
        next.answered[requestID] = approving
        save(next)
        defer { if undelivered.remove(requestID) != nil { publish() } }
        do {
            let lease = try await AnswerDoor.answer(upload, at: door) { [weak self] in
                Task { @MainActor in self?.undelivered.insert(requestID); self?.publish() }
            }
            var ended = work
            ended.outcome = lease
            receive(ended)
            PhoneDiagnostics.log.note("answer", "delivered", ["request": requestID, "state": "\(lease.state)"])
            PhoneNotifications.remove(requestID)
        } catch {
            PhoneDiagnostics.log.note("answer", "not delivered", ["request": requestID, "error": "\(error)"])
            Task { await uploadLog() }
            var undo = state
            undo.answered[requestID] = nil
            save(undo)
            throw error
        }
    }

    /// Answers that cannot reach the asking computer yet and are still being retried.
    private var undelivered: Set<String> = []

    /// Ends an approval early, at the asking computer's door: its next use of the password fails.
    public func stop(_ requestID: String) async throws {
        let work = try currentWork(requestID)
        let request = try Sealing.parseRequest(work.request)
        guard let door = Sealing.answerDoor(request), let keyID = state.deviceKeyID else {
            throw PhoneMacDoor.Failure.notAllowed("The request names no door.")
        }
        var end = Agentkeyring_V2_EndRequest()
        end.domain = "agentkeyring.end.v2"
        end.requestID = requestID
        end.deviceKeyID = keyID
        end.endedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signed = try Sealing.signed(end.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        let lease = try Agentkeyring_V2_Lease(serializedBytes: await AnswerDoor.end(signed, at: door))
        var ended = work
        ended.outcome = lease
        receive(ended)
    }

    // MARK: Rules and devices

    /// Changes a login's rule from the Passwords tab, after one Face ID. The Mac makes and withdraws the
    /// copies the new rule needs.
    public func setRule(_ rule: PhoneLogin.Rule, forLogin loginID: String) async throws {
        guard var next = catalogue, let index = next.logins.firstIndex(where: { $0.loginID == loginID }) else { return }
        let old = next.logins[index]
        let wanted: Agentkeyring_V2_Rule = switch rule {
        case .ask: .ask
        case .automatic: .automatic
        case .blocked: .blocked
        }
        guard wanted != old.rule else { return }
        let context = LAContext()
        defer { context.invalidate() }
        let computers = members?.machines.map(\.label) ?? []
        let reason = rule == .automatic && !computers.isEmpty
            ? PhoneCopy.automaticReason(site: Self.site(old), from: Self.rule(old), computers: computers)
            : PhoneCopy.faceIDSetRule(site: Self.site(old), rule: rule)
        try await keys.authorize(context, reason: reason)
        next.logins[index].rule = wanted
        next.revision += 1
        let signed = try Sealing.signed(next.serializedData(), by: Sealing.keyID(keys.signingPublicKey())) { try keys.sign($0, context: context) }
        _ = try await mac().post("/v2/catalogue", signed.serializedData())
        try accept(catalogue: signed)
    }

    /// Removes a device or computer: the next Members, signed after Face ID.
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
        _ = try await self.mac().post("/v2/members", signed.serializedData())
        try accept(members: signed)
    }

    /// What this iPhone signs its sealed copies with: its reply key, which needs no Face ID.
    private var sealSigner: Sealing.Signer {
        Sealing.Signer(keyID: (try? Sealing.keyID(keys.replyPublicKey())) ?? "", sign: keys.signReply)
    }

    // MARK: Joining the Mac

    /// The Mac's join card in iCloud Keychain, serialized `JoinInvite`. Nil when there is none, for
    /// example in the simulator, which has no iCloud Keychain.
    private func joinCard() -> Agentkeyring_V2_JoinInvite? {
        if let linked = linkedCard { return linked }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.joshpalmer.AgentKeyring.invitation",
                                    kSecAttrAccount as String: "relay", kSecAttrSynchronizable as String: true,
                                    kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String ?? "",
                                    kSecUseDataProtectionKeychain as String: true, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let card = try? Agentkeyring_V2_JoinInvite(serializedBytes: data) else { return nil }
        return card
    }

    /// A card that can be joined: the Mac's door at a Tailscale address, its key, and a secret.
    private static func joinable(_ card: Agentkeyring_V2_JoinInvite) -> Bool {
        Tailnet.isAddress(card.doorHost) && card.doorPort > 0 && card.doorPort <= UInt32(UInt16.max)
            && !card.doorTlsPublicKey.isEmpty && !card.secret.isEmpty
    }

    /// Reads the Mac's join card every three seconds while first run looks for it. The read is local;
    /// iCloud's sync between devices is what takes time, so two minutes with nothing is `lookedLong`.
    private func lookForMac() {
        guard looking == nil, state.deviceKeyID == nil else { return }
        let since = Date()
        looking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.firstRun.looksForMac, self.state.deviceKeyID == nil else { break }
                if let card = self.joinCard(), Self.joinable(card) {
                    self.foundMac = card
                    self.apply(.macFound(name: card.inviterLabel.isEmpty ? nil : card.inviterLabel))
                } else {
                    self.foundMac = nil
                    self.apply(.macGone)
                    if Date().timeIntervalSince(since) >= 120 { self.apply(.lookedLong) }
                }
                try? await Task.sleep(for: .seconds(3))
            }
            self?.looking = nil
        }
    }

    private var looking: Task<Void, Never>?
    /// The join card the look last found.
    private var foundMac: Agentkeyring_V2_JoinInvite? { didSet { if foundMac != oldValue { publish() } } }
    /// A card opened as a link (the simulator has no iCloud Keychain).
    private var linkedCard: Agentkeyring_V2_JoinInvite?

    public func join(invitation link: String) async throws {
        guard state.deviceKeyID == nil, let url = URLComponents(string: link), url.scheme == "agentkeyring", url.host == "join",
              let encoded = url.queryItems?.first(where: { $0.name == "invite" })?.value,
              let bytes = Data(base64URL: encoded), let card = try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes) else { return }
        linkedCard = card
        lookForMac()
    }

    /// This iPhone as it asks to join.
    private func joinRequest(_ card: Agentkeyring_V2_JoinInvite) throws -> Agentkeyring_V2_JoinRequest {
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
        joining.proof = Sealing.joinProof(secret: card.secret, joining: joining)
        return joining
    }

    /// Asks the Mac to join at its door, posting again while the answer is still waiting. Leaving the app
    /// cuts the call; the request stays waiting on the Mac and is posted again on return. A Mac that cannot
    /// be reached at all is said so; one that stops answering after it said "waiting" is tried for 30 seconds.
    private func joinMac() {
        guard joining == nil, state.deviceKeyID == nil else { return }
        joining = Task { [weak self] in
            defer { self?.joining = nil }
            guard let self, let card = self.foundMac ?? self.joinCard(), Self.joinable(card) else {
                self?.apply(.macUnreachable); return
            }
            let door = MacDoor(host: card.doorHost, port: UInt16(card.doorPort), key: card.doorTlsPublicKey,
                               name: card.inviterLabel.isEmpty ? "Mac" : card.inviterLabel)
            var lastHeard: Date?
            while !Task.isCancelled, self.firstRun.mayJoin {
                do {
                    let joining = try self.joinRequest(card)
                    let reply = try await self.macDoor(door).post("/v2/join", joining.serializedData(), timeout: 35)
                    let status = try Agentkeyring_V2_JoinStatus(serializedBytes: reply)
                    lastHeard = Date()
                    switch status.state {
                    case .waiting: continue
                    case .approved: return try self.joined(status, card: card, door: door, device: joining.device)
                    case .refused: return self.apply(.joinRefused)
                    case .expired: return self.apply(.joinExpired)
                    default: return  // withdrawn: Cancel already moved first run
                    }
                } catch is CancellationError { return }
                catch {
                    if Task.isCancelled { return }
                    PhoneDiagnostics.log.note("join", "not answered", ["error": "\(error)"])
                    guard let heard = lastHeard, Date().timeIntervalSince(heard) < AnswerDoor.retryFor else { return self.apply(.macUnreachable) }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private var joining: Task<Void, Never>?

    private func joined(_ status: Agentkeyring_V2_JoinStatus, card: Agentkeyring_V2_JoinInvite, door: MacDoor,
                        device: Agentkeyring_V2_Device) throws {
        let members = try Sealing.verifiedMembers(status.members, current: nil)
        guard status.members.signerKeyID == card.inviterKeyID, members.devices.contains(where: { $0 == device }) else {
            throw PhoneMacDoor.Failure.notAllowed("The approval does not match this iPhone.")
        }
        var next = state
        next.deviceKeyID = device.keyID
        next.mac = door
        save(next)
        try accept(members: status.members)
        PhoneDiagnostics.log.note("join", "joined", ["device": String(device.keyID.prefix(16))])
        looking?.cancel(); looking = nil
        apply(.joined)
        start()
    }

    /// Cancel while waiting: the Mac drops the request at once.
    private func withdrawJoin() async {
        joining?.cancel(); joining = nil
        guard let card = foundMac ?? joinCard(), Self.joinable(card) else { return }
        let door = MacDoor(host: card.doorHost, port: UInt16(card.doorPort), key: card.doorTlsPublicKey, name: card.inviterLabel)
        do { _ = try await macDoor(door).post("/v2/join/withdraw", joinRequest(card).serializedData()) }
        catch { PhoneDiagnostics.log.note("join", "withdraw not sent", ["error": "\(error)"]) }
    }

    /// Added: fetches this iPhone's copies until every password not Blocked has one, then first run goes on.
    /// The Mac may still be encrypting them; after a minute with no more arriving, first run goes on anyway
    /// and the rest come with the next fetch.
    private func receivePasswords() async {
        var lastCount = -1
        var lastGrowth = Date()
        while firstRun == .receivingPasswords {
            if await refresh(), let expected = copiesExpected, copiesHeld >= expected { break }
            if copiesHeld != lastCount { lastCount = copiesHeld; lastGrowth = Date() }
            if Date().timeIntervalSince(lastGrowth) > 60 {
                PhoneDiagnostics.log.note("join", "copies incomplete", ["held": "\(copiesHeld)", "expected": "\(copiesExpected ?? 0)"])
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }
        apply(.passwordsReceived)
    }

    // MARK: Notifications

    /// What iOS allows, as the app last read it: for the checklist and whether a practice push will come.
    private var facts = PhoneNotificationFacts() { didSet { publish() } }

    public func notificationFacts(_ next: PhoneNotificationFacts) async {
        guard next != facts else { return }
        facts = next
        PhoneDiagnostics.log.note("notifications", "read", ["allowed": "\(next.allowed)", "banners": "\(next.banners)",
            "lockScreen": "\(next.lockScreen)", "timeSensitive": "\(next.timeSensitive)", "scheduledSummary": "\(next.inScheduledSummary)"])
    }

    private var phoneSettings: PhoneSettings {
        let saved = state.settings ?? NotificationSettings()
        return PhoneSettings(timeSensitive: saved.timeSensitive, quietHours: saved.quietHours, quietFrom: saved.quietFrom, quietTo: saved.quietTo)
    }

    public func dismiss(_ notice: PhoneNotice) async {}

    /// Kept for the extension in the shared keychain item, and handed to Apple Watch.
    public func setSettings(_ settings: PhoneSettings) async {
        var saved = NotificationSettings()
        saved.timeSensitive = settings.timeSensitive; saved.quietHours = settings.quietHours
        saved.quietFrom = settings.quietFrom; saved.quietTo = settings.quietTo
        var next = state
        next.settings = saved
        save(next)
        onListsChanged?()
    }

    /// The app hands the lists and settings to Apple Watch whenever they change.
    public var onListsChanged: (() -> Void)?
    public var notificationSettings: NotificationSettings { state.settings ?? NotificationSettings() }

    // MARK: Practice

    /// The practice request while first run has it open.
    private var practiceOpen: AccessRequest? {
        guard case let .practice(id) = firstRun else { return nil }
        return practiceWork(id).flatMap { work in (try? Sealing.parseRequest(work.request)).map(Self.practiceRequest) }
    }

    /// The practice request in the real request's layout, with the board's words.
    nonisolated static func practiceRequest(_ request: KeyringRequest) -> AccessRequest {
        .practice(id: request.requestID, askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)),
                  until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
    }

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
        guard let mine = state.deviceKeyID, let request = try? Sealing.parseRequest(work.request) else { return false }
        return request.forDeviceKeyID == mine && request.loginID.isEmpty
    }

    /// How the last practice request ended, for the log.
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

    /// Asks the Mac for this iPhone's practice request, by its id: the same id again rejoins it. It
    /// arrives pushed, like any request, which shows that requests reach the phone. The Mac must be
    /// awake: if its door cannot be reached, first run says so.
    private func askForPractice(_ id: String) {
        practiceTask?.cancel()
        practiceTask = Task { [weak self] in
            defer { self?.practiceTask = nil }
            guard let self, let mine = self.state.deviceKeyID else { return }
            do {
                let made = try await self.askMacForPractice(for: mine, id: id)
                PhoneDiagnostics.log.note("practice", "made", ["request": made])
                self.apply(.practiceSent(id: made))
                if self.practiceWork(made) != nil { self.apply(.practiceArrived(pushExpected: self.facts.allowed && self.pushRegistered)) }
            } catch is CancellationError {
            } catch {
                PhoneDiagnostics.log.note("practice", "not made", ["error": "\(error)"])
                self.apply(.practiceMacUnreachable)
            }
        }
    }

    /// The Mac makes and pushes a practice request for this iPhone or its Watch; returns its id.
    private func askMacForPractice(for deviceID: String, id: String) async throws -> String {
        var ask = Agentkeyring_V2_PracticeAsk()
        ask.domain = "agentkeyring.practice.v2"
        ask.forDeviceKeyID = deviceID
        ask.requestID = id
        let signed = try Sealing.signed(ask.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
        let background = PhoneBackgroundTime.begin("A practice request")
        defer { PhoneBackgroundTime.end(background) }
        let reply = try await mac().post("/v2/practice", signed.serializedData())
        let made = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return made.isEmpty ? id : made
    }

    /// First run's practice request, approved with one Face ID: a signed answer with no delivery.
    func approvePractice(_ work: Work) async throws {
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
        try await send(upload, for: work, approving: true)
    }

    /// Send Practice Request on Home, or Practice on Apple Watch's row. For this iPhone, the one already
    /// waiting is returned to be shown again instead of a second being made.
    public func sendPractice(to deviceID: String?) async -> String? {
        guard let deviceID, deviceID != state.deviceKeyID else {
            if let waiting = waitingPractice, let id = try? Sealing.parseRequest(waiting.request).requestID { return id }
            guard let mine = state.deviceKeyID else { return nil }
            do { _ = try await askMacForPractice(for: mine, id: PhoneFirstRun.newPracticeID()) }
            catch { PhoneDiagnostics.log.note("practice", "not made", ["error": "\(error)"]) }
            return nil
        }
        do { _ = try await askMacForPractice(for: deviceID, id: PhoneFirstRun.newPracticeID()) }
        catch { PhoneDiagnostics.log.note("practice", "not made", ["device": String(deviceID.prefix(16)), "error": "\(error)"]) }
        return nil
    }

    // MARK: Apple Watch

    /// Try Practice on Apple Watch: the Mac makes its practice request. False if the Mac cannot be reached.
    public func practiceForWatch() async -> Bool {
        guard let watch = members?.devices.first(where: { $0.kind == .watch }) else { return false }
        do { _ = try await askMacForPractice(for: watch.keyID, id: PhoneFirstRun.newPracticeID()); return true }
        catch { PhoneDiagnostics.log.note("practice", "not made", ["device": "watch", "error": "\(error)"]); return false }
    }

    /// What WatchConnectivity says: an Apple Watch is paired, and Agent Keyring's Watch app is on it.
    public func watchPairing(paired: Bool, installed: Bool) {
        guard (paired, installed) != (watchPaired, watchInstalled) else { return }
        watchPaired = paired; watchInstalled = installed
        PhoneDiagnostics.log.note("watch", "pairing", ["paired": "\(paired)", "installed": "\(installed)"])
        applyAddWatch(.checked(paired: paired, installed: installed))
        publish()
    }
    private var watchPaired = false
    private var watchInstalled = false

    /// The Apple Watch's facts, from WatchConnectivity, its self-test, and the list of devices.
    private func watchFacts(_ members: Members) -> PhoneWatchFacts {
        let test = watchTest
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

    private var watchTest: [String: Any] {
        state.watchSelfTest.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
    }

    /// The Watch's own self-test, as its app sent it.
    public func watchTested(_ plist: Data) {
        var next = state
        next.watchSelfTest = plist
        save(next)
        if watchTest["passcodeSet"] as? Bool == false { applyAddWatch(.watchHasNoPasscode) }
    }

    /// The flow that adds Apple Watch, while it is open.
    private var addWatchFlow: PhoneAddWatch?
    /// The Face ID confirmation held for Apple Watch to ask, and when it ends.
    private var held: (context: LAContext, until: Date)?
    private var holdTimer: Task<Void, Never>?

    /// The Watch offers Add only while this is set: the end of the held confirmation.
    public var onWatchMayAsk: ((Date?) -> Void)?

    private func applyAddWatch(_ event: PhoneAddWatch.Event) {
        guard let flow = addWatchFlow else { return }
        let next = flow.on(event)
        guard next != flow else { return }
        PhoneDiagnostics.log.note("addwatch", "moved", ["from": "\(flow)", "to": "\(next)", "by": "\(event)"])
        addWatchFlow = next == .closed ? nil : next
        if !next.watchMayAsk, flow.watchMayAsk || next == .closed { onWatchMayAsk?(nil) }
        if case let .waitingForWatch(until) = next { onWatchMayAsk?(until) }
        if next == .faceIDExpired || next == .closed { releaseHold() }
        if next == .closed, firstRun == .addWatch { apply(.done) }
        publish()
        // Apple Watch already asked, or is listed but lacks its copies: carry on at once.
        if case .waitingForWatch = next, state.watchDevice != nil || watchLacksCopies { addWatchNow() }
    }

    private func openAddWatch() {
        addWatchFlow = .start(paired: watchPaired, installed: watchInstalled)
        publish()
    }

    public func addWatch(_ tap: PhoneAddWatchTap) async {
        switch tap {
        case .open: if addWatchFlow == nil { openAddWatch() }
        case .checkAgain: applyAddWatch(.checked(paired: watchPaired, installed: watchInstalled))
        case .continueWithFaceID: await confirmForWatch()
        case .tryAgain:
            if case .copiesFailed = addWatchFlow { held == nil ? applyAddWatch(.confirmationLapsed) : addWatchNow() }
            else { applyAddWatch(.tryAgain(now: Date())) }
        case .cancel: applyAddWatch(.cancel)
        case .done: applyAddWatch(.done)
        }
    }

    /// Face ID first, with its reason; the confirmation is then held until its shown end, and nothing is
    /// decrypted until Apple Watch asks.
    private func confirmForWatch() async {
        let context = LAContext()
        do { try await keys.authorize(context, reason: PhoneCopy.faceIDAddWatch) }
        catch { context.invalidate(); PhoneDiagnostics.log.note("addwatch", "face id not given", ["error": "\(error)"]); return }
        releaseHold()
        let until = Date().addingTimeInterval(PhoneAddWatch.hold)
        held = (context, until)
        holdTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(PhoneAddWatch.hold)) } catch { return }
            self?.applyAddWatch(.confirmationLapsed)
        }
        applyAddWatch(.confirmed(until: until))
    }

    private func releaseHold() {
        holdTimer?.cancel(); holdTimer = nil
        held?.context.invalidate(); held = nil
    }

    /// Apple Watch is listed but the Mac holds none of its copies.
    private var watchLacksCopies: Bool {
        if case .copiesFailed = addWatchFlow { return true }
        return false
    }

    /// The Watch's app sent its keys after Add, its push address, or both. The keys are kept until the
    /// iPhone is waiting with a held confirmation; the push address goes to the Mac once the Watch is listed.
    public func watchOffered(device: Data?, push: Data?) {
        let parsed = device.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
        let pushRegistration = push.flatMap { try? Agentkeyring_V2_PushRegistration(serializedBytes: $0) }
        let listed = members?.devices.first { $0.kind == .watch && $0.keyID == (parsed?.keyID ?? pushRegistration?.deviceKeyID) }
        if listed != nil {
            if let pushRegistration { Task { await registerWatchPush(pushRegistration) } }
            return
        }
        var next = state
        if let parsed, parsed.kind == .watch, let device { next.watchDevice = device }
        if let push { next.watchPush = push }
        save(next)
        if parsed != nil, case .waitingForWatch = addWatchFlow { addWatchNow() }
    }

    private func registerWatchPush(_ registration: Agentkeyring_V2_PushRegistration) async {
        do {
            try await post(registration)
            var done = state
            done.watchPush = nil
            save(done)
        } catch { PhoneDiagnostics.log.note("watch", "push address not registered", ["error": "\(error)"]) }
    }

    /// With the held confirmation: lists Apple Watch, encrypts a copy of each password for it, and sends
    /// them to the Mac, which gives them to the computers that put them in the Watch's pushes. If the copies
    /// do not reach the Mac, the Watch stays listed and Try Again sends only the copies.
    private func addWatchNow() {
        guard addingWatch == nil else { return }
        addingWatch = Task { [weak self] in
            guard let self else { return }
            defer { self.addingWatch = nil }
            guard let (context, until) = self.held, until > Date() else { return self.applyAddWatch(.confirmationLapsed) }
            let copies = self.ownCopies
            self.applyAddWatch(.watchAsked(total: copies.count))
            do {
                guard var members = self.members, let catalogue = self.catalogue else { throw PhoneMacDoor.Failure.notJoined }
                let watch: Agentkeyring_V2_Device
                if let listed = members.devices.first(where: { $0.kind == .watch && $0.keyID == self.pendingWatch?.keyID }) {
                    watch = listed
                } else if let pending = self.pendingWatch {
                    watch = pending
                    members.revision += 1
                    members.devices.append(watch)
                    let signed = try Sealing.signed(members.serializedData(), by: Sealing.keyID(self.keys.signingPublicKey())) {
                        try self.keys.sign($0, context: context)
                    }
                    _ = try await self.mac().post("/v2/members", signed.serializedData())
                    try self.accept(members: signed)
                } else { throw PhoneMacDoor.Failure.notAllowed("Apple Watch has not asked.") }
                let watchKey = try P256.KeyAgreement.PublicKey(x963Representation: watch.openingPublicKey)
                let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
                var forWatch = Agentkeyring_V2_SealedLogins()
                for (index, copy) in copies.values.enumerated() {
                    guard let login = listed[copy.loginID], login.rule != .blocked else { continue }
                    try Sealing.checkSealed(copy, members: members, listed: login)
                    forWatch.logins.append(try Sealing.seal(self.keys.open(copy, context: context), version: copy.version,
                                                            to: watchKey, openerID: watch.keyID, signer: self.sealSigner))
                    if index % 25 == 0 { self.applyAddWatch(.encrypted(done: index, total: copies.count)) }
                }
                _ = try await self.mac().post("/v2/copies", forWatch.serializedData())
                PhoneDiagnostics.log.note("addwatch", "copies sent", ["count": "\(forWatch.logins.count)"])
                var done = self.state
                done.watchDevice = nil
                self.save(done)
                if let push = self.state.watchPush.flatMap({ try? Agentkeyring_V2_PushRegistration(serializedBytes: $0) }) {
                    await self.registerWatchPush(push)
                }
                self.applyAddWatch(.copiesSent)
            } catch {
                PhoneDiagnostics.log.note("addwatch", "copies failed", ["error": "\(error)"])
                self.applyAddWatch(.copiesFailed(reason: "\(error)"))
            }
        }
    }

    private var addingWatch: Task<Void, Never>?
    private var pendingWatch: Agentkeyring_V2_Device? {
        state.watchDevice.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
            ?? members?.devices.first { $0.kind == .watch }
    }

    /// The signed lists, for Apple Watch.
    public var signedMembers: Data? { state.members }
    public var signedCatalogue: Data? { state.catalogue }

    // MARK: Logs

    /// The recent log, Apple Watch's lines with it, signed with the reply key, for the Mac to keep:
    /// `agent-keyring logs` reads it back. Sent on leaving the screen, every 5 minutes while open, and after an answer fails.
    public func uploadLog() async {
        guard let keyID = state.deviceKeyID, state.mac != nil else { return }
        PhoneDiagnostics.log.collect()
        var log = Agentkeyring_V2_DeviceLog()
        log.domain = "agentkeyring.log.v2"
        log.deviceKeyID = keyID
        log.lines = PhoneDiagnostics.log.lines()
        let background = PhoneBackgroundTime.begin("Log upload")
        defer { PhoneBackgroundTime.end(background) }
        do {
            let signed = try Sealing.signed(log.serializedData(), by: Sealing.keyID(keys.replyPublicKey())) { try keys.signReply($0) }
            _ = try await mac().post("/v2/log", signed.serializedData())
        } catch { logger.error("Log not uploaded: \(String(describing: error), privacy: .public)") }
    }

    // MARK: Requests as the screens show them

    private func accessRequest(_ work: Work, _ members: Members, _ catalogue: Catalogue?) -> AccessRequest? {
        guard let request = try? Sealing.parseRequest(work.request) else { return nil }
        let now = Int64(Date().timeIntervalSince1970)
        if isPracticeWork(work) {
            var practice = Self.practiceRequest(request)
            if work.hasOutcome { practice.state = Self.state(work.outcome, now: now, members: members) }
            else if request.answerByUnixSeconds <= now { practice.state = .unanswered }
            return practice
        }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { return nil }
        let login = catalogue?.logins.first { $0.loginID == request.loginID }
        let state: AccessRequestState
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
            agent: RequestingAgent(name: request.agent.isEmpty ? PhoneCopy.anAgent : request.agent, machine: machine.label, address: "",
                                   project: request.project.isEmpty ? nil : request.project),
            access: .login,
            agentReason: request.reason, askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)), state: state)
    }

    nonisolated static func state(_ lease: Lease, now: Int64, members: Members? = nil) -> AccessRequestState {
        let notAfter = Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds))
        // "Approved on your Mac" when a Mac answered. Only a Mac in the list of devices counts.
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

    // MARK: For the notification service extension

    /// Tells the asking computer a request has reached this iPhone, from the notification extension. The
    /// phone may be locked, so it signs nothing: the note names the push address instead, and grants nothing.
    nonisolated public static func noteArrival(_ requestID: String, door: AnswerDoor.Door?, shared: PhoneSharedContext) async throws {
        guard let door else { throw PhoneMacDoor.Failure.notAllowed("The request names no door.") }
        guard let saved = shared.read(), let keyID = saved.deviceKeyID, let hash = saved.pushTokenSHA256 else { throw PhoneMacDoor.Failure.notJoined }
        var arrival = Agentkeyring_V2_Arrival()
        arrival.domain = "agentkeyring.arrival.v2"
        arrival.requestID = requestID
        arrival.deviceKeyID = keyID
        arrival.arrivedUnixSeconds = Int64(Date().timeIntervalSince1970)
        arrival.pushTokenSha256 = hash
        var note = SignedDocument()
        note.payload = try arrival.serializedData()
        try await AnswerDoor.arrived(note, at: door)
    }

    /// Whether a request arriving now may break through a Focus, from the iPhone's Settings.
    nonisolated public static func breaksThroughFocus(_ shared: PhoneSharedContext) -> Bool {
        (shared.read()?.settings ?? NotificationSettings()).breaksThroughFocus()
    }

    /// The request a push is about, as the Lock Screen shows it: the notice opened, the login and computer
    /// named from the saved Catalogue and Members.
    nonisolated public static func notifiedRequest(_ userInfo: [AnyHashable: Any], shared: PhoneSharedContext,
                                                   open: (Agentkeyring_V2_Notice, String) throws -> Agentkeyring_V2_Work) -> PhoneNotified? {
        let log = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Notice")
        func fail(_ step: String) -> PhoneNotified? {
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
        do {
            let named = try named(work, members: members, catalogue: catalogue, keyID: keyID)
            return PhoneNotified(request: named.request, answeredBy: named.answeredBy,
                                 door: (try? Sealing.parseRequest(work.request)).flatMap(Sealing.answerDoor))
        } catch { return fail("\(error)") }
    }

    /// A notified request as the Lock Screen shows it, and where to tell its computer it arrived.
    public struct PhoneNotified {
        public let request: AccessRequest
        public let answeredBy: String?
        public let door: AnswerDoor.Door?
        public init(request: AccessRequest, answeredBy: String?, door: AnswerDoor.Door?) {
            self.request = request; self.answeredBy = answeredBy; self.door = door
        }
    }

    public struct Unnamed: Error, CustomStringConvertible {
        public let description: String
    }

    /// An opened notice's request, named from the signed Members and Catalogue only: this iPhone's own
    /// practice request, or one the computer it names signed.
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
            || next.settings != state.settings || next.pushTokenSHA256 != state.pushTokenSHA256
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
