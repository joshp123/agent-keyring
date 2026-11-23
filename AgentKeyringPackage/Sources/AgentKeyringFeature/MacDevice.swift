// Written by AI on 2026.11.18 by model claude opus 5.5; rebuilt on 2026.11.21
// by the same model for the direct design, with no relay.
//
// The Mac as the one place Josh's lists live. It keeps the signed members list
// and catalogue, every sealed copy (LoginStore) and each device's push
// address, and serves them on its Tailscale address with its machine TLS key
// (keyring.proto, "Direct: no relay"), through two doors: port 17447, which
// requires a member's client certificate, for joining (MacJoins.swift) and the
// lists; and port 17446, the answer door every asking computer has, with no
// client certificate. Its own agents' requests go to the iPhone and Apple Watch
// as pushes this Mac sends to Apple, and come back to the answer door (MacAsks.swift).
// Agents' requests on other computers are shown here too, and answered at
// their own doors; a Stop a device could not take there waits here (MacRemoteAsks.swift).

import AgentKeyringProtocol
import AgentKeyringRelaySupport
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Observation
import OSLog
import Security
import SwiftProtobuf

let deviceLogger = Logger(subsystem: "com.agentkeyring.app", category: "Door")

@MainActor @Observable
public final class MacDevice {
    /// The doors, which everything else depends on: both open, or neither.
    public enum Door: Equatable, Sendable {
        case opening
        /// This Mac has no Tailscale address: Tailscale is not installed, not
        /// running, or signed out. Nothing can reach this Mac, and it reaches nothing.
        case noTailscale
        /// `answers`: the answer door; `members`: the members' door, named in invitations.
        case open(host: String, answers: UInt16, members: UInt16)
        /// A port could not be opened, such as when another program holds it.
        case failed(String)

        public var address: String? { if case let .open(host, port, _) = self { Tailnet.join(host, port) } else { nil } }
    }

    /// What the Mac keeps between launches, beside the sealed copies in LoginStore.
    struct Saved: Codable {
        var members: Data?               // Signed Members.
        var membersHistory: [Data] = []  // Every Signed Members since the first, oldest first.
        var catalogue: Data?        // Signed Catalogue: the one served.
        var catalogueRevision: UInt64 = 0
        var copiesRevision: UInt64 = 0
        var registrations: [String: Data] = [:]  // Device key ID: Signed PushRegistration.
    }

    /// What differs between the app and a test: where the door listens, where pushes go, where things are kept.
    public struct Environment {
        public var address: @MainActor () -> String? = { Tailnet.address() }
        public var answerPort: UInt16 = 17446
        public var membersPort: UInt16 = 17447
        public var gateway = ApplePush.Gateway.apple
        public var storage: MacStorage
        /// The invitation left in iCloud Keychain for a new iPhone.
        public var invitationItem: InvitationItem = .iCloud
        public var joinWait: Duration = .seconds(25)
        public var complaints: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/complaints.pb")
        /// The clock for how long a Stop left here is kept.
        public var now: @MainActor () -> Date = { .now }
        public init(storage: MacStorage) { self.storage = storage }
    }

    public private(set) var door = Door.opening
    public private(set) var members: Agentkeyring_V2_Members?
    /// The catalogue as last signed: what devices and computers are given.
    public private(set) var catalogue: Agentkeyring_V2_Catalogue?
    var saved: Saved
    @ObservationIgnored var deviceLogs: [String: [String]] = [:]
    /// Observed: the Devices tab drops its "no push key" notice when the key arrives.
    var push: ApplePush?
    @ObservationIgnored var servers: [DoorServer] = []
    @ObservationIgnored private var doorGeneration = UUID()
    @ObservationIgnored private var doorWork: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var revPush: Task<Void, Never>?

    let keys: MacKeys
    let store: LoginStore
    let leaseStore: CredentialLeaseStore
    let environment: Environment
    /// The logins and their rules as the catalogue, from the app's import and rules.
    let catalogueLogins: @MainActor () async throws -> [Agentkeyring_V2_Login]
    /// A newer catalogue the iPhone signed (a rule changed there), with this Mac's own Automatic copies as it now holds them.
    @ObservationIgnored var onCatalogue: (@MainActor (Agentkeyring_V2_Catalogue) async -> Void)?
    /// The catalogue was signed and sent: the other devices now hold this Mac's list as it is.
    @ObservationIgnored var onPublished: (@MainActor () async -> Void)?
    /// A device asked for a practice request on this Mac itself.
    @ObservationIgnored var onPracticeHere: (@MainActor () -> Void)?
    /// Membership or computer Automatic-copy state changed, so the app should refresh local Automatic status.
    @ObservationIgnored var onAutomaticCopiesChanged: (@MainActor () async -> Void)?

    // Joining (MacJoins.swift).
    var joinRecords: [String: Join] = [:]
    @ObservationIgnored var invitations: [Data: Date] = [:]
    let joinSignal = Signal()
    public internal(set) var filling: Filling?

    // Asking (MacAsks.swift).
    var asks: [String: Ask] = [:]
    let askSignal = Signal()
    @ObservationIgnored var pushChains: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var leaseFollowing: Task<Void, Never>?

    // Other computers' requests, and Stops left here (MacRemoteAsks.swift).
    public internal(set) var remoteAsks: [String: RemoteAsk] = [:]
    @ObservationIgnored var stops: [String: KeptStop] = [:]

    init(keys: MacKeys, store: LoginStore, leaseStore: CredentialLeaseStore, environment: Environment,
        catalogueLogins: @escaping @MainActor () async throws -> [Agentkeyring_V2_Login]) {
        self.keys = keys
        self.store = store
        self.leaseStore = leaseStore
        self.environment = environment
        self.catalogueLogins = catalogueLogins
        saved = environment.storage.read("saved").flatMap { try? PropertyListDecoder().decode(Saved.self, from: $0) } ?? Saved()
        members = saved.members.flatMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }
            .flatMap { try? Agentkeyring_V2_Members(serializedBytes: $0.payload) }
        if let members {
            catalogue = saved.catalogue.flatMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }
                .flatMap { try? Sealing.verifiedCatalogue($0, members: members, current: nil) }
        }
        if let bytes = environment.storage.read("push"), let credential = try? Agentkeyring_V2_PushCredential(serializedBytes: bytes) {
            push = try? ApplePush(credential: credential, gateway: environment.gateway)
        }
    }

    /// The Mac has members: at least one device or computer has joined it.
    public var hasMembers: Bool { members != nil }
    public var ownMachineID: String { keys.machineID }
    public var ownDeviceID: String { keys.deviceKeyID }
    public var hasPushKey: Bool { push != nil }

    func persist() {
        do { try environment.storage.write(PropertyListEncoder().encode(saved), "saved") } catch {
            deviceLogger.error("Could not save the lists: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: The door

    /// Opens the door on this Mac's Tailscale address, and keeps it there: when
    /// the address appears, changes or goes, the door follows.
    public func start() {
        guard pathMonitor == nil else { return }
        followLeases()
        resumeAsks()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.followAddress() } }
        monitor.start(queue: DispatchQueue(label: "com.agentkeyring.door-path"))
        pathMonitor = monitor
        followAddress()
    }

    /// One change of the door at a time.
    func followAddress() {
        let previous = doorWork
        doorWork = Task { [weak self] in
            await previous?.value
            await self?.reconcileDoor()
        }
    }

    func reconcileDoor() async {
        guard let host = environment.address() else {
            closeDoor(.noTailscale)
            return
        }
        if case let .open(open, _, _) = door, open == host { return }
        closeDoor(.opening)
        do {
            let doorGeneration = UUID()
            self.doorGeneration = doorGeneration
            let onServerClosed: @Sendable (Error) -> Void = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.doorGeneration == doorGeneration else { return }
                    DiagnosticLog.record("door", "listener-failed", ["error": "\(error)"])
                    self.closeDoor(.failed("\(error)"))
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        self?.followAddress()
                    }
                }
            }
            let answers = try DoorServer(identity: keys.tls, host: host, port: environment.answerPort, onClosed: onServerClosed) { [weak self] request in
                await self?.routeAnswers(request) ?? .refused(503, "Agent Keyring is closing.")
            }
            let members = try DoorServer(identity: keys.tls, host: host, port: environment.membersPort, requireClientCertificate: true, onClosed: onServerClosed) { [weak self] request in
                await self?.routeMembers(request) ?? .refused(503, "Agent Keyring is closing.")
            }
            servers = [answers, members]
            let answerPort = try await answers.start()
            guard self.doorGeneration == doorGeneration else {
                answers.stop()
                members.stop()
                return
            }
            let membersPort = try await members.start()
            guard self.doorGeneration == doorGeneration else {
                answers.stop()
                members.stop()
                return
            }
            door = .open(host: host, answers: answerPort, members: membersPort)
            DiagnosticLog.record("door", "open", ["answers": Tailnet.join(host, answerPort), "members": Tailnet.join(host, membersPort)])
            leaveInvitation()
        } catch {
            closeDoor(.failed("\(error)"))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.followAddress()
            }
        }
    }

    private func closeDoor(_ next: Door) {
        doorGeneration = UUID()
        for server in servers { server.stop() }
        servers = []
        if door != next {
            DiagnosticLog.record("door", "closed", ["state": "\(next)"])
            door = next
            if next == .noTailscale { leaveInvitation() }
        }
    }

    /// Who is calling, by the TLS key the connection showed: a device or a computer in the members list.
    enum Caller {
        case device(Agentkeyring_V2_Device)
        case machine(Agentkeyring_V2_Machine)

        var label: String {
            switch self {
            case let .device(device): device.label
            case let .machine(machine): machine.label
            }
        }
    }

    func caller(_ spki: Data?) -> Caller? {
        guard let spki, !spki.isEmpty, let members else { return nil }
        if let device = members.devices.first(where: { $0.tlsPublicKey == spki }) { return .device(device) }
        return members.machines.first { $0.tlsPublicKey == spki }.map(Caller.machine)
    }

    /// The answer door: answers, arrival notes and Stop for this Mac's own requests, from anyone; each carries its own proof.
    func routeAnswers(_ request: DoorRequest) async -> DoorReply {
        switch (request.method, request.path) {
        case ("POST", "/v2/answer"): return await takeAnswer(request.body)
        case ("POST", "/v2/arrived"): return takeArrival(request.body)
        case ("POST", "/v2/end"): return takeEnd(request.body)
        default: return .refused(404, "This is the Mac's answer door. Joining and the lists are on its members' door, the one its invitation names.")
        }
    }

    /// The members' door: joining, and the lists for a device or computer that has joined.
    func routeMembers(_ request: DoorRequest) async -> DoorReply {
        switch (request.method, request.path) {
        case ("POST", "/v2/join"): return await takeJoin(request)
        case ("POST", "/v2/join/withdraw"): return takeWithdrawal(request)
        default: break
        }
        guard let caller = caller(request.peerSPKI) else {
            // A device or computer removed from Members may still fetch the signed Members chain
            // proving its removal (with zero catalogue, copies, or push data) so it can safely reset.
            if request.method == "GET", request.path == "/v2/bundle", wasPreviouslyMember(request.peerSPKI) {
                return .ok(message(removalBundle(holding: UInt64(request.query["members"] ?? "") ?? 0)))
            }
            return .refused(403, "Only a device or computer that has joined this Mac may use this. Join with an invitation from the Mac.")
        }
        let device: Agentkeyring_V2_Device? = if case let .device(device) = caller { device } else { nil }
        let onlyDevices = DoorReply.refused(403, "Only an iPhone or Apple Watch in the user's list of devices may do this.")
        switch (request.method, request.path) {
        case ("GET", "/v2/rev"): return .ok(message(revisions))
        case ("GET", "/v2/bundle"): return .ok(message(await bundle(for: caller, holding: UInt64(request.query["members"] ?? "") ?? 0)))
        case ("GET", "/v2/logs"): return .ok(message(logs(since: Int64(request.query["since"] ?? "") ?? 0)))
        case ("POST", "/v2/complaint"): return takeComplaint(request.body, from: caller)
        case ("GET", "/v2/complaints"): return .ok(message(complaints(since: Int64(request.query["since"] ?? "") ?? 0)))
        case ("POST", "/v2/push-registration"): return device == nil ? onlyDevices : takeRegistration(request.body)
        case ("GET", "/v2/copies"): return device == nil ? onlyDevices : await checkCopiesComplete(for: request.query["complete_for"] ?? "")
        case ("POST", "/v2/copies"): return device == nil ? onlyDevices : await takeCopies(request.body, completeFor: request.query["complete_for"])
        case ("POST", "/v2/catalogue"): return device == nil ? onlyDevices : await takeCatalogue(request.body)
        case ("POST", "/v2/members"): return device == nil ? onlyDevices : await takeMembers(request.body)
        case ("POST", "/v2/practice"): return device == nil ? onlyDevices : takePracticeAsk(request.body)
        case ("POST", "/v2/log"): return device == nil ? onlyDevices : takeLog(request.body)
        case ("POST", "/v2/ask"): return takeRemoteAsk(request.body, from: caller)
        case ("POST", "/v2/outcome"): return takeRemoteOutcome(request.body, from: caller)
        case ("POST", "/v2/stop"): return device == nil ? onlyDevices : takeStop(request.body)
        case ("GET", "/v2/stops"): return stop(for: request.query["request"] ?? "", from: caller)
        default: return .refused(404, "There is no \(request.method) \(request.path) on this Mac.")
        }
    }

    func message(_ message: some SwiftProtobuf.Message) -> Data { (try? message.serializedData()) ?? Data() }

    // MARK: Lists served

    public var revisions: Agentkeyring_V2_Revisions {
        var revisions = Agentkeyring_V2_Revisions()
        revisions.members = members?.revision ?? 0
        revisions.catalogue = catalogue?.revision ?? 0
        revisions.copies = saved.copiesRevision
        return revisions
    }

    /// Everything one caller keeps: the lists, every members revision it lacks,
    /// the push addresses, and its own copies. Only copies of the signed catalogue's
    /// current version are given, never a Blocked one: an import Josh has not
    /// yet approved sending stays here.
    /// `holding`: the newest members revision the caller has; every later one comes too, oldest first.
    func bundle(for caller: Caller, holding: UInt64) async -> Agentkeyring_V2_Bundle {
        var bundle = Agentkeyring_V2_Bundle()
        if let bytes = saved.members, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) { bundle.members = signed }
        bundle.membersSince = saved.membersHistory.compactMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }.filter { signed in
            ((try? Agentkeyring_V2_Members(serializedBytes: signed.payload))?.revision ?? 0) > holding
        }
        if let bytes = saved.catalogue, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) { bundle.catalogue = signed }
        bundle.pushRegistrations = saved.registrations.keys.sorted().compactMap { saved.registrations[$0].flatMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) } }
        bundle.revisions = revisions
        guard let catalogue, let members else { return bundle }
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let watches = Set(members.devices.filter { $0.kind == .watch }.map(\.keyID))
        bundle.copies = ((try? await store.sealed()) ?? []).filter { copy in
            guard let login = listed[copy.loginID], login.rule != .blocked, login.version == copy.version else { return false }
            switch caller {
            case let .device(device): return copy.openerID == device.keyID
            case let .machine(machine):
                if copy.openerID == machine.machineID { return login.rule == .automatic }
                return watches.contains(copy.openerID)
            }
        }
        return bundle
    }

    /// True if `spki` belonged to a device or computer in an earlier signed Members revision.
    private func wasPreviouslyMember(_ spki: Data?) -> Bool {
        guard let spki, !spki.isEmpty else { return false }
        return saved.membersHistory.contains { bytes in
            guard let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes),
                  let past = try? Agentkeyring_V2_Members(serializedBytes: signed.payload) else { return false }
            return past.devices.contains(where: { $0.tlsPublicKey == spki })
                || past.machines.contains(where: { $0.tlsPublicKey == spki })
        }
    }

    /// Signed Members proof only (no catalogue, copies, or push registrations) for a removed peer.
    private func removalBundle(holding: UInt64) -> Agentkeyring_V2_Bundle {
        var bundle = Agentkeyring_V2_Bundle()
        if let bytes = saved.members, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) { bundle.members = signed }
        bundle.membersSince = saved.membersHistory.compactMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }.filter { signed in
            ((try? Agentkeyring_V2_Members(serializedBytes: signed.payload))?.revision ?? 0) > holding
        }
        bundle.revisions = revisions
        return bundle
    }

    /// The lists or a copy changed: the iPhone hears it from a silent push, a second later.
    func listsChanged(copies: Bool = false) {
        if copies { saved.copiesRevision += 1 }
        persist()
        revPush?.cancel()
        revPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.sendRevisionsPush()
        }
    }

    private func sendRevisionsPush() async {
        guard let push, let members else { return }
        let payload = PushPayload.revisions(revisions)
        for phone in members.devices where phone.kind == .iphone {
            guard let registration = registration(for: phone.keyID) else { continue }
            do {
                try await push.send(payload, to: registration, collapseID: "rev", expiration: Int64(Date.now.timeIntervalSince1970) + 86400, visible: false)
            } catch {
                DiagnosticLog.record("push", "rev-not-sent", ["device": phone.label, "reason": "\(error)"])
            }
        }
    }

    func registration(for deviceKeyID: String) -> Agentkeyring_V2_PushRegistration? {
        saved.registrations[deviceKeyID].flatMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }
            .flatMap { try? Agentkeyring_V2_PushRegistration(serializedBytes: $0.payload) }
    }

    /// A signed document from a device in the members list, by its reply key or signing key.
    func fromDevice(_ body: Data) -> (document: Agentkeyring_V2_Signed, device: Agentkeyring_V2_Device)? {
        guard let members, let document = try? Agentkeyring_V2_Signed(serializedBytes: body),
            let device = try? Sealing.verify(document, members: members, allowReplyKey: true) else { return nil }
        return (document, device)
    }

    // MARK: What devices send

    func takeRegistration(_ body: Data) -> DoorReply {
        guard let (document, signer) = fromDevice(body),
            let registration = try? Agentkeyring_V2_PushRegistration(serializedBytes: document.payload),
            registration.domain == "agentkeyring.push.v2" else {
            return .refused(403, "A push registration is signed by a device in the list of devices.")
        }
        guard let target = members?.devices.first(where: { $0.keyID == registration.deviceKeyID }),
            target.keyID == signer.keyID || (target.kind == .watch && signer.kind == .iphone) else {
            return .refused(403, "A device registers its own push address, or its iPhone registers its Apple Watch's.")
        }
        guard !registration.apnsToken.isEmpty, !registration.apnsTopic.isEmpty,
            (try? P256.KeyAgreement.PublicKey(x963Representation: registration.noticePublicKey)) != nil else {
            return .refused(400, "A push registration needs a push address, a topic and a notice key.")
        }
        if let current = self.registration(for: target.keyID), current.registeredUnixSeconds > registration.registeredUnixSeconds {
            return .ok() // A newer one is held: the newest wins.
        }
        saved.registrations[target.keyID] = body
        persist()
        DiagnosticLog.record("push", "registered", ["device": target.label, "production": "\(registration.apnsProduction)"])
        return .ok()
    }

    func takeMembers(_ body: Data) async -> DoorReply {
        guard let document = try? Agentkeyring_V2_Signed(serializedBytes: body) else { return .refused(400, "The body must be a signed members list.") }
        do {
            let next = try Sealing.verifiedMembers(document, current: members)
            await adoptMembers(next, signed: body)
            return .ok()
        } catch {
            return .refused(403, "This members list was refused: \(error).")
        }
    }

    /// A newer members list, signed here or on the iPhone. A device or computer it leaves out keeps nothing here.
    func adoptMembers(_ next: Agentkeyring_V2_Members, signed: Data) async {
        let known = Set(next.devices.map(\.keyID) + next.machines.map(\.machineID))
        members = next
        saved.members = signed
        saved.membersHistory.append(signed)
        saved.registrations = saved.registrations.filter { known.contains($0.key) }
        let ownDeviceKeyID = keys.deviceKeyID
        _ = try? await store.updateSealed { current in
            guard current.contains(where: { !known.contains($0.openerID) && $0.openerID != ownDeviceKeyID }) else { return current }
            return current.filter { known.contains($0.openerID) || $0.openerID == ownDeviceKeyID }
        }
        DiagnosticLog.record("members", "changed", ["revision": "\(next.revision)", "devices": "\(next.devices.count)", "computers": "\(next.machines.count)"])
        listsChanged(copies: true)
        await onAutomaticCopiesChanged?()
    }

    func takeCatalogue(_ body: Data) async -> DoorReply {
        guard let document = try? Agentkeyring_V2_Signed(serializedBytes: body) else {
            return .refused(400, "The body must be a signed catalogue.")
        }
        return await withSerializedCatalogue { [self] in
            guard let members else {
                return .refused(400, "The body must be a signed catalogue.")
            }
            let next: Agentkeyring_V2_Catalogue
            do { next = try Sealing.verifiedCatalogue(document, members: members, current: catalogue) } catch {
                return .refused(403, "This catalogue was refused: \(error).")
            }
            catalogue = next
            saved.catalogue = body
            saved.catalogueRevision = next.revision
            await onCatalogue?(next)
            listsChanged(copies: true)
            DiagnosticLog.record("catalogue", "changed", ["revision": "\(next.revision)"])
            return .ok()
        }
    }

    /// Copies made on the iPhone (its Apple Watch's, or a computer's Automatic
    /// ones), each checked against its signer and the catalogue's version. This
    /// Mac's own copies come only from its own import.
    func takeCopies(_ body: Data, completeFor: String? = nil) async -> DoorReply {
        guard let members, let catalogue, let batch = try? Agentkeyring_V2_SealedLogins(serializedBytes: body) else {
            return .refused(400, "The body must be sealed copies, sent once the Mac has a catalogue.")
        }
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let openers = Set(members.devices.map(\.keyID) + members.machines.map(\.machineID)).subtracting([keys.deviceKeyID])
        var kept: [Agentkeyring_V2_SealedLogin] = []
        for copy in batch.logins {
            guard openers.contains(copy.openerID) else { return .refused(403, "A copy names an opener that is not another device or computer in the user's list.") }
            guard let login = listed[copy.loginID] else { return .refused(403, "A copy is of a password the catalogue does not list.") }
            guard login.rule != .blocked else { continue }
            do { try Sealing.checkSealed(copy, members: members, listed: login) } catch {
                return .refused(403, "A copy was not sealed by one of the user's devices, or is of another version.")
            }
            kept.append(copy)
        }
        let cleared = Set(batch.clearedOpeners).intersection(openers)
        let machines = Set(members.machines.map(\.machineID))
        let withdrawn = Set(batch.withdrawnLoginIds)
        let replaced = Set(kept.map { $0.openerID + "/" + $0.loginID })
        let incoming = kept
        let stored: [Agentkeyring_V2_SealedLogin]
        do {
            stored = try await store.updateSealed { current in
                var next = current
                next.removeAll { cleared.contains($0.openerID) || (withdrawn.contains($0.loginID) && machines.contains($0.openerID)) }
                next.removeAll { replaced.contains($0.openerID + "/" + $0.loginID) }
                return next + incoming
            }
        } catch { return .refused(503, "The Mac could not save the copies. Try again.") }
        listsChanged(copies: true)
        if let completeFor, !completeFor.isEmpty {
            return verifyWatchCoverage(completeFor, stored: stored)
        }
        return .ok()
    }

    /// Confirms whether a listed Apple Watch currently has matching-version copies for every
    /// non-Blocked login in this Mac's current catalogue (used on upgrade reconciliation and upload completion).
    func checkCopiesComplete(for watchKeyID: String) async -> DoorReply {
        guard !watchKeyID.isEmpty else { return .refused(400, "Specify complete_for.") }
        let stored = (try? await store.sealed()) ?? []
        return verifyWatchCoverage(watchKeyID, stored: stored)
    }

    private func verifyWatchCoverage(_ watchKeyID: String, stored: [Agentkeyring_V2_SealedLogin]) -> DoorReply {
        guard let liveMembers = self.members,
              liveMembers.devices.contains(where: { $0.kind == .watch && $0.keyID == watchKeyID }),
              let liveCatalogue = self.catalogue else {
            return .refused(409, "Apple Watch is no longer listed or the catalogue changed.")
        }
        let byLogin = Dictionary(stored.filter { $0.openerID == watchKeyID }.map { ($0.loginID, $0.version) },
                                 uniquingKeysWith: { _, latest in latest })
        let complete = liveCatalogue.logins.allSatisfy { login in
            login.rule == .blocked || byLogin[login.loginID] == login.version
        }
        guard complete else {
            return .refused(409, "Some passwords in this Mac's current catalogue are not copied for Apple Watch yet.")
        }
        return .ok()
    }

    func takeLog(_ body: Data) -> DoorReply {
        guard let (document, signer) = fromDevice(body), let log = try? Agentkeyring_V2_DeviceLog(serializedBytes: document.payload),
            log.domain == "agentkeyring.log.v2", log.deviceKeyID == signer.keyID else {
            return .refused(403, "A log is signed by the device it comes from.")
        }
        deviceLogs[signer.keyID] = Array(log.lines.suffix(1000))
        return .ok()
    }

    /// This Mac's lines and each device's latest log, in time order, for `agent-keyring logs` and GET /v2/logs.
    public func logLines(since: Int64, request: String = "") -> [String] {
        let from = since > 0 ? Date(timeIntervalSince1970: TimeInterval(since))
            .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) : ""
        let devices = deviceLogs.values.joined().filter { $0 >= from && (request.isEmpty || $0.contains(request)) }
        return Array(Set(DiagnosticLog.recent(since: since, request: request) + devices)).sorted()
    }

    func logs(since: Int64) -> Agentkeyring_V2_Logs {
        var logs = Agentkeyring_V2_Logs()
        logs.lines = logLines(since: since)
        return logs
    }

    // MARK: Complaints

    /// An agent's complaint, from a computer through the door or from this Mac's own agent.
    func takeComplaint(_ body: Data, from caller: Caller) -> DoorReply {
        guard case .machine = caller, var complaint = try? Agentkeyring_V2_Complaint(serializedBytes: body),
            complaint.domain == "agentkeyring.complaint.v2" else {
            return .refused(400, "The body must be a complaint, from a computer that has joined.")
        }
        complaint.computer = caller.label // Each computer speaks only for itself.
        do { try keep(complaint) } catch { return .refused(503, "The Mac could not keep the complaint. Try again.") }
        return .ok()
    }

    /// Kept in one owner-only file, oldest first; shown on no screen.
    public func keep(_ complaint: Agentkeyring_V2_Complaint) throws {
        var complaint = complaint
        guard complaint.summary.utf8.count <= 1000, complaint.detail.utf8.count <= 65_536 else {
            throw RelayFailure(.invalidArgument, "Keep a complaint's summary to one line and its detail under 64 KB.")
        }
        if complaint.atUnixSeconds == 0 { complaint.atUnixSeconds = Int64(Date.now.timeIntervalSince1970) }
        var all = complaints(since: 0)
        all.complaints.append(complaint)
        all.complaints = Array(all.complaints.suffix(5000))
        let file = environment.complaints
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try all.serializedData().write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        DiagnosticLog.record("complaint", "kept", ["computer": complaint.computer])
    }

    public func complaints(since: Int64) -> Agentkeyring_V2_Complaints {
        var all = (try? Data(contentsOf: environment.complaints)).flatMap { try? Agentkeyring_V2_Complaints(serializedBytes: $0) }
            ?? Agentkeyring_V2_Complaints()
        all.complaints = all.complaints.filter { $0.atUnixSeconds >= since }
        return all
    }

    // MARK: The push key

    /// The Apple developer team's push key, from `agent-keyring push-key`: kept
    /// in this app's keychain, used for this Mac's pushes and sealed to each
    /// computer that joins.
    public func setPushCredential(keyID: String, teamID: String, privateKey: Data) throws {
        guard !keyID.isEmpty, !teamID.isEmpty, (try? P256.Signing.PrivateKey(derRepresentation: privateKey)) != nil else {
            throw RelayFailure(.invalidArgument, MessageCopy.invalidPushKey)
        }
        var credential = Agentkeyring_V2_PushCredential()
        credential.keyID = keyID
        credential.teamID = teamID
        credential.privateKey = privateKey
        let made = try ApplePush(credential: credential, gateway: environment.gateway)
        try environment.storage.write(credential.serializedData(), "push")
        push = made
        DiagnosticLog.record("push", "key-saved", ["key_id": keyID])
    }

    // MARK: Signing, with Touch ID

    /// macOS's own dialog, with our sentence after "Agent Keyring is trying to".
    func confirm(_ context: LAContext, reason: String, until deadline: Date = .now.addingTimeInterval(600)) async throws {
        try await OwnerConfirmation.confirm(context, reason: reason, until: deadline)
        try Task.checkCancellation()
    }

    func publishMembers(_ next: Agentkeyring_V2_Members, context: LAContext) async throws {
        var next = next
        next.domain = "agentkeyring.members.v2"
        next.revision = (members?.revision ?? 0) + 1
        let signed = try Sealing.signed(next.serializedData(), by: keys.deviceKeyID) { try keys.sign($0, context: context) }
        await adoptMembers(next, signed: try signed.serializedData())
    }

    private var catalogueOperation: (id: UUID, task: Task<Void, Never>)?

    /// Runs `body` exclusively across local `publish(context:)`, incoming `takeCatalogue(_:)`, and imports,
    /// so publications never read half-applied rules, reuse a signed revision, or race with an import's copy retention.
    func withSerializedCatalogue<T: Sendable>(_ body: @MainActor @escaping () async throws -> T) async throws -> T {
        while let inFlight = catalogueOperation?.task {
            await inFlight.value
        }
        let runID = UUID()
        var outcome: Result<T, Error>?
        let task = Task { @MainActor in
            defer { if self.catalogueOperation?.id == runID { self.catalogueOperation = nil } }
            do { outcome = .success(try await body()) }
            catch { outcome = .failure(error) }
        }
        catalogueOperation = (runID, task)
        await task.value
        return try outcome!.get()
    }

    private func withSerializedCatalogue<T: Sendable>(_ body: @MainActor @escaping () async -> T) async -> T {
        while let inFlight = catalogueOperation?.task {
            await inFlight.value
        }
        let runID = UUID()
        var outcome: T?
        let task = Task { @MainActor in
            defer { if self.catalogueOperation?.id == runID { self.catalogueOperation = nil } }
            outcome = await body()
        }
        catalogueOperation = (runID, task)
        await task.value
        return outcome!
    }

    /// Signs the catalogue with Touch ID: the devices and computers take its
    /// rules, and the copies of its versions, from the next bundle.
    /// Serialized with incoming catalogue adoption so publications never undo an iPhone rule change or reuse a revision.
    public func publish(context: LAContext) async throws {
        try await withSerializedCatalogue {
            guard self.members != nil else { return }
            var next = Agentkeyring_V2_Catalogue()
            next.domain = "agentkeyring.catalogue.v2"
            next.logins = try await self.catalogueLogins()
            // Allocate revision synchronously AFTER awaiting catalogueLogins so no concurrent
            // catalogue update can take the same revision number.
            next.revision = max(self.saved.catalogueRevision, self.catalogue?.revision ?? 0) + 1
            next.importedUnixSeconds = Int64(Date().timeIntervalSince1970)
            let signed = try Sealing.signed(next.serializedData(), by: self.keys.deviceKeyID) { try self.keys.sign($0, context: context) }
            self.catalogue = next
            self.saved.catalogue = try signed.serializedData()
            self.saved.catalogueRevision = next.revision
            // Prune versions older than the signed catalogue while preserving any newer concurrent import.
            let versions = Dictionary(next.logins.map { ($0.loginID, $0.version) }, uniquingKeysWith: { first, _ in first })
            let ownDeviceKeyID = self.keys.deviceKeyID
            _ = try await self.store.updateSealed { sealed in
                sealed.filter { copy in
                    guard let published = versions[copy.loginID] else { return copy.openerID == ownDeviceKeyID }
                    return copy.version >= published
                }
            }
            self.listsChanged(copies: true)
            DiagnosticLog.record("catalogue", "signed", ["revision": "\(next.revision)", "passwords": "\(next.logins.count)"])
            await self.onPublished?()
        }
    }

    /// Check Again: reads this Mac's Tailscale address now, as a change of network would.
    public func checkAddress() {
        followAddress()
    }

    /// Upgrades any legacy `automaticAllowed == false` entries in Members to `true` so older Go clients
    /// that still inspect the field accept Automatic passwords on every enrolled computer.
    func allowAutomaticOnAllMachines(context: LAContext) async throws {
        guard let members else { return }
        var next = members
        for index in next.machines.indices {
            next.machines[index].automaticAllowed = true
        }
        guard next != members else { return }
        try await publishMembers(next, context: context)
    }

    /// The model changed the copies held for these computers.
    func sendCopies(for machineIDs: Set<String>) {
        guard hasMembers, !machineIDs.isEmpty else { return }
        listsChanged(copies: true)
    }

    /// Removes a computer or another device, after Josh's Touch ID; the system dialog is the confirmation.
    public func removeConfirmed(_ id: String, context: LAContext) async throws {
        guard let initial = members else { return }
        let label = initial.machines.first { $0.machineID == id }?.label ?? initial.devices.first { $0.keyID == id }?.label ?? "it"
        try await confirm(context, reason: MessageCopy.remove(label))
        // Re-read current Members after Touch ID so a concurrent removal by another device is never undone.
        guard var next = members else { return }
        let beforeDevices = next.devices.count
        let beforeMachines = next.machines.count
        next.machines.removeAll { $0.machineID == id }
        next.devices.removeAll { $0.keyID == id && $0.keyID != keys.deviceKeyID }
        guard next.devices.count != beforeDevices || next.machines.count != beforeMachines else { return }
        try await publishMembers(next, context: context)
    }

    /// Renames a device or another computer in Members, after owner confirmation, so every device shows the new name.
    public func renameConfirmed(_ id: String, to newName: String, context: LAContext) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let initial = members else { return }
        let current = initial.machines.first { $0.machineID == id }?.label ?? initial.devices.first { $0.keyID == id }?.label ?? "it"
        guard trimmed != current else { return }
        try await confirm(context, reason: MessageCopy.rename(current, to: trimmed))
        // Re-read current Members after Touch ID so a member removed during the prompt is never resurrected.
        guard var next = members else { return }
        if let idx = next.devices.firstIndex(where: { $0.keyID == id }) {
            next.devices[idx].label = trimmed
        } else if let idx = next.machines.firstIndex(where: { $0.machineID == id }) {
            next.machines[idx].label = trimmed
        } else {
            return
        }
        try await publishMembers(next, context: context)
    }

    /// The other openers each login must be sealed to: devices' opening keys,
    /// and every enrolled computer's receiving key for Automatic logins.
    public func otherOpeners(automatic: Bool) -> [(id: String, key: P256.KeyAgreement.PublicKey)] {
        guard let members else { return [] }
        let devices = members.devices.filter { $0.keyID != keys.deviceKeyID }.compactMap { device in
            (try? P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)).map { (device.keyID, $0) }
        }
        guard automatic else { return devices }
        return devices + members.machines.filter { $0.machineID != keys.machineID }.compactMap { machine in
            (try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)).map { (machine.machineID, $0) }
        }
    }

}


/// Where the Mac keeps its lists and its push key: the app's own keychain,
/// where no other program running as Josh can read or change them; files in
/// the container with the stand-in key; memory in tests.
public struct MacStorage {
    let read: @MainActor (String) -> Data?
    let write: @MainActor (Data, String) throws -> Void

    static let service = (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".lists.v2"

    @MainActor public static func app(standIn: Bool) -> MacStorage {
        #if DEBUG
        if standIn {
            let folder = URL.applicationSupportDirectory.appending(path: "AgentKeyring/stand-in-lists")
            return MacStorage(read: { try? Data(contentsOf: folder.appending(path: $0)) }, write: { bytes, account in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try bytes.write(to: folder.appending(path: account), options: .atomic)
            })
        }
        #endif
        let keychain = RelayKeychain(service: service, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        return MacStorage(read: { try? keychain.read($0) }, write: { try keychain.write($0, account: $1) })
    }

    @MainActor public static func memory() -> MacStorage {
        final class Box: @unchecked Sendable { var items: [String: Data] = [:] } // Touched only on the main actor.
        let box = Box()
        return MacStorage(read: { box.items[$0] }, write: { box.items[$1] = $0 })
    }
}

/// Wakes everything waiting on a change: a join's long poll, a practice request's progress.
@MainActor
final class Signal {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func fire() {
        let all = waiters
        waiters = [:]
        for waiter in all.values { waiter.resume() }
    }

    /// Returns on the next change, or at `deadline`.
    func wait(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(until: deadline)
                    self?.resume(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
    }

    private func resume(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
