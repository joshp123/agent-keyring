// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The MacBook as an approving device on the relay (protocol version 2). It
// sees requests from agents on other machines, and machines and devices
// asking to join, and answers them with Touch ID: approving opens the one
// sealed login with the Mac's chip key and seals it again for the machine that
// asked. Agents on this Mac never go through here; they ask the Mac directly.

import AgentKeyringProtocol
import AgentKeyringRelaySupport
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import OSLog
import Security

private let deviceLogger = Logger(subsystem: "com.agentkeyring.app", category: "Relay")

@MainActor @Observable
public final class MacDevice {
    public enum Connection: Equatable, Sendable { case notSetUp, connecting, connected, unreachable }

    /// What this Mac knows of the relay, saved between launches.
    struct Saved: Codable {
        var endpoint: RelayEndpoint
        var pin: Data
        var members: Data       // Signed Members, checked when it arrived.
        var catalogueRevision: UInt64
        var alwaysOnMachineID: String? = nil
    }

    public private(set) var connection = Connection.notSetUp
    /// Requests from agents on other machines that nobody has answered yet.
    public private(set) var waiting: [String: Agentkeyring_V2_Work] = [:]
    /// This Mac's agents' requests passed on to the iPhone and Watch: lease ID to relay request ID.
    @ObservationIgnored private var askedForAgents: [String: String] = [:]
    /// Requests answered here or elsewhere, newest outcome last, for the menu bar.
    public private(set) var finished: [String: Agentkeyring_V2_Work] = [:]
    public private(set) var joins: [Agentkeyring_V2_PendingJoin] = []
    public private(set) var members: Agentkeyring_V2_Members?
    /// Each device's last self-test that passed, by key id, as the relay keeps them.

    let keys: MacKeys
    let store: LoginStore
    /// The logins and their rules as the catalogue, from the app's import and rules.
    let catalogueLogins: @MainActor () async throws -> [Agentkeyring_V2_Login]
    /// A newer catalogue another device signed (a rule changed on the iPhone),
    /// with this Mac's own Automatic copies as the relay now holds them.
    var onCatalogue: (@MainActor (Agentkeyring_V2_Catalogue, [Agentkeyring_V2_SealedLogin]) async -> Void)?
    /// Not set up, an agent setting up the computer that stays on, or joined
    /// to its relay. Only Touch ID on "add Mac mini" moves it to joined.
    private enum Lifecycle {
        case notSetUp
        case settingUp(Setup)
        case joined(Saved)
    }

    private var lifecycle = Lifecycle.notSetUp
    private var saved: Saved? {
        get { if case let .joined(saved) = lifecycle { saved } else { nil } }
        set { if let newValue { lifecycle = .joined(newValue) } else if case .joined = lifecycle { lifecycle = .notSetUp } }
    }
    private var hiddenJoins = Set<String>()
    /// Invitations this Mac issued and nobody has used: secret, expiry. A join
    /// is shown only if its proof checks against one of them.
    private var invitations: [Data: Date] = [:]
    @ObservationIgnored private var running: Task<Void, Never>?
    /// The saved relay and members live in the app's own keychain, where no
    /// other program running as Josh can read or change them.
    private let keychain = RelayKeychain(service: (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".relay.v2",
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

    init(keys: MacKeys, store: LoginStore, catalogueLogins: @escaping @MainActor () async throws -> [Agentkeyring_V2_Login]) {
        self.keys = keys
        self.store = store
        self.catalogueLogins = catalogueLogins
        if let bytes = readSaved(), let saved = try? PropertyListDecoder().decode(Saved.self, from: bytes) {
            self.saved = saved
            members = Self.parse(saved.members)
        }
    }

    public var isJoined: Bool { saved != nil }
    /// The waiting requests, read from their bytes.
    public var waitingRequests: [Agentkeyring_V2_Request] { waiting.values.compactMap { try? Sealing.parseRequest($0.request) } }
    public var ownMachineID: String { keys.machineID }
    public var ownDeviceID: String { keys.deviceKeyID }
    /// The computer that stays on, as the signed list names it; older lists only on this Mac.
    public var alwaysOnMachineID: String? {
        if let id = members?.relayMachineID, !id.isEmpty { return id }
        return saved?.alwaysOnMachineID
    }

    private static func parse(_ signed: Data) -> Agentkeyring_V2_Members? {
        guard let document = try? Agentkeyring_V2_Signed(serializedBytes: signed) else { return nil }
        return try? Agentkeyring_V2_Members(serializedBytes: document.payload)
    }

    private func readSaved() -> Data? {
        #if DEBUG
        if keys.standIn { return try? Data(contentsOf: Self.standInFile) }
        #endif
        return try? keychain.read("saved")
    }

    private func persist() throws {
        let bytes = try PropertyListEncoder().encode(saved)
        #if DEBUG
        if keys.standIn {
            try FileManager.default.createDirectory(at: Self.standInFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try bytes.write(to: Self.standInFile, options: .atomic)
        }
        #endif
        try keychain.write(bytes, account: "saved")
    }

    #if DEBUG
    /// With the stand-in key, in the container beside its keys, so a fresh container starts fresh.
    private static let standInFile = URL.applicationSupportDirectory.appending(path: "AgentKeyring/stand-in-relay.plist")
    #endif

    private var relay: KeyringRelay? {
        guard let saved else { return nil }
        return KeyringRelay(endpoint: saved.endpoint, identity: keys.tls, pin: saved.pin)
    }

    private func call(_ method: Agentkeyring_V2_RelayRequest.OneOf_Method) async throws -> Agentkeyring_V2_RelayResponse {
        guard let relay else { throw RelayFailure(.unavailable, "This Mac is not connected to a relay.") }
        var request = Agentkeyring_V2_RelayRequest()
        request.method = method
        return try await relay.call(request)
    }

    // MARK: Setting up

    /// An agent on this Mac is setting up the always-on machine that runs the relay.
    public struct Setup: Equatable {
        public let endpoint: RelayEndpoint
        public let agent: String
        public let reason: String
        /// The always-on machine, once its join proves the setup invitation.
        public internal(set) var machine: Agentkeyring_V2_Machine?
        /// Its command can be told it was denied (it sent a refusal key's hash).
        public internal(set) var refusable = false
        /// The relay's TLS key, as first seen.
        let pin: Data
        /// The setup invitation's one-time secret.
        let secret: Data
    }

    public private(set) var setup: Setup? {
        get { if case let .settingUp(setup) = lifecycle { setup } else { nil } }
        set { if let newValue { lifecycle = .settingUp(newValue) } else if case .settingUp = lifecycle { lifecycle = .notSetUp } }
    }
    @ObservationIgnored private var setupWatch: Task<Void, Never>?

    /// An agent ran `agent-keyring setup-relay`: note the relay's key, and give
    /// the agent an invitation for the always-on machine. The request appears
    /// beside the pointer once that machine asks to join with it.
    public func beginSetup(_ endpoint: RelayEndpoint, agent: String, reason: String) async throws -> String {
        guard saved == nil else { throw RelayFailure(.conflict, "This Mac is already connected to a relay.") }
        var observed = Data()
        var request = Agentkeyring_V2_RelayRequest()
        request.method = .members(Agentkeyring_V2_Empty())
        _ = try? await KeyringRelay(endpoint: endpoint, identity: keys.tls, pin: nil).call(request) { observed = $0 }
        guard !observed.isEmpty else { throw RelayFailure(.unavailable, "The relay could not be reached at \(endpoint.host).") }
        let invite = invitation(endpoint: endpoint, pin: observed, lasting: 600)
        setup = Setup(endpoint: endpoint, agent: agent, reason: reason, pin: observed, secret: invite.secret)
        leaveDeviceInvitation(endpoint: endpoint, pin: observed)
        setupWatch?.cancel()
        setupWatch = Task { [weak self] in
            while let self, !Task.isCancelled, self.setup != nil, self.setup?.machine == nil {
                var request = Agentkeyring_V2_RelayRequest()
                request.method = .pendingJoins(Agentkeyring_V2_Empty())
                if let response = try? await KeyringRelay(endpoint: endpoint, identity: self.keys.tls, pin: observed).call(request),
                    let secret = self.setup?.secret {
                    let proven = response.pendingJoins.joins.filter { Sealing.joinProof(secret: secret, joining: $0.request) == $0.request.proof }
                    if Set(proven.map(Self.joinID)).count > 1 {
                        deviceLogger.error("Two machines proved the setup invitation; setup is cancelled.")
                        self.abandonSetup()
                        return
                    }
                    if let join = proven.first, case let .machine(machine)? = join.request.joining {
                        self.setup?.machine = machine
                        self.setup?.refusable = !join.request.refusalKeySha256.isEmpty
                    }
                    let invited = response.pendingJoins.joins.filter { join in
                        self.invitations.keys.contains { Sealing.joinProof(secret: $0, joining: join.request) == join.request.proof }
                    }
                    if !invited.isEmpty {
                        deviceLogger.notice("\(invited.count, privacy: .public) proven join(s) wait for setup to finish.")
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        return "agentkeyring://join?invite=" + (try invite.serializedData()).base64URLEncoded
    }

    /// Josh denied the computer that stays on: the agent waiting on its
    /// enrol hears at once, with his words. Setup ends either way. True if
    /// the relay took the denial.
    public func refuseSetup(reply: String) async -> Bool {
        defer { abandonSetup() }
        guard let setup, setup.refusable, let machine = setup.machine else { return false }
        let secret = setup.secret
        var request = Agentkeyring_V2_RelayRequest()
        request.method = .refuseJoin(Self.refusal(machineID: machine.machineID, secret: secret, reply: reply))
        do {
            _ = try await KeyringRelay(endpoint: setup.endpoint, identity: keys.tls, pin: setup.pin).call(request)
            return true
        } catch {
            deviceLogger.error("Could not tell \(machine.label, privacy: .public) it was denied: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func refusal(machineID: String, secret: Data, reply: String) -> Agentkeyring_V2_JoinRefusal {
        var refusal = Agentkeyring_V2_JoinRefusal()
        refusal.joinerID = machineID
        refusal.key = Sealing.refusalKey(secret: secret, machineID: machineID)
        refusal.reply = reply
        refusal.replyProof = Sealing.refusalReplyProof(secret: secret, machineID: machineID, reply: reply)
        return refusal
    }

    public func abandonSetup() {
        setupWatch?.cancel()
        setup = nil
    }

    /// Josh approved with Touch ID: this Mac becomes the first device, and the
    /// computer that stays on and this Mac the first computers, at this relay.
    /// The new computer gets no Automatic passwords until he sets one to
    /// Automatic and approves the computers the rule bar names.
    public func confirmSetup(thisMacAutomatic: Bool, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        guard let setup, let always = setup.machine else { return }
        let pin = setup.pin
        try await confirm(context, reason: "add \(always.label)")
        onAuthenticated()
        var thisMac = keys.machine
        thisMac.automaticAllowed = thisMacAutomatic
        var members = Agentkeyring_V2_Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [keys.device]
        members.machines = [thisMac, always]
        members.relayTlsPublicKey = pin
        members.relayMachineID = always.machineID
        let signed = try Sealing.signed(members.serializedData(), by: keys.deviceKeyID) { try keys.sign($0, context: context) }
        saved = Saved(endpoint: setup.endpoint, pin: pin, members: try signed.serializedData(), catalogueRevision: 0,
            alwaysOnMachineID: always.machineID)
        do {
            _ = try await call(.publishMembers(signed))
        } catch {
            lifecycle = .settingUp(setup)
            throw error
        }
        self.members = members
        try persist()
        abandonSetup()
        try await publish(context: context)
        start()
    }

    /// Josh gave the address of a relay already running on a computer of his
    /// that stays on: no command runs on this Mac. After his Touch ID this Mac
    /// is the first device there, and the only computer, until an agent adds
    /// others. A relay this Mac already belongs to (its keys survive a new
    /// install) is joined again as it is; one that belongs to other devices is refused.
    public func connect(to endpoint: RelayEndpoint, context: LAContext, expecting: Data? = nil, proof: Data? = nil,
        onAuthenticated: @MainActor () -> Void) async throws {
        if let saved {
            if saved.endpoint == endpoint { return } // Walking first run again on a Mac already connected there.
            throw RelayFailure(.conflict, "This Mac is already connected to the computer at \(saved.endpoint.host).")
        }
        var pin = Data()
        var request = Agentkeyring_V2_RelayRequest()
        request.method = .members(Agentkeyring_V2_Empty())
        let response = try? await KeyringRelay(endpoint: endpoint, identity: keys.tls, pin: nil).call(request) { pin = $0 }
        guard !pin.isEmpty else { throw RelayFailure(.unavailable, "Nothing answered at \(endpoint.host):\(endpoint.port). Check that the computer is on and its relay is running.") }
        if let expecting, expecting != pin { throw RelayFailure(.permissionDenied, "The computer at \(endpoint.host) is not the one that announced itself.") }
        var existing: (document: Agentkeyring_V2_Signed, members: Agentkeyring_V2_Members)?
        if case let .signed(document)? = response?.result, !document.payload.isEmpty {
            guard let members = try? Sealing.verifiedMembers(document, current: nil),
                members.devices.contains(where: { $0.keyID == keys.deviceKeyID && $0.signingPublicKey == keys.device.signingPublicKey }) else {
                throw RelayFailure(.conflict, "That relay is already set up with other devices.")
            }
            existing = (document, members)
        }
        try await confirm(context, reason: "connect to the computer that stays on at \(endpoint.host)")
        onAuthenticated()
        DiagnosticLog.record("relay", "connect", ["host": endpoint.host, "port": "\(endpoint.port)", "rejoined": existing == nil ? "no" : "yes"])
        if let existing {
            saved = Saved(endpoint: endpoint, pin: pin, members: try existing.document.serializedData(), catalogueRevision: 0,
                alwaysOnMachineID: existing.members.relayMachineID.isEmpty ? nil : existing.members.relayMachineID)
            members = existing.members
            // The next catalogue must be newer than the one the relay and the iPhone hold.
            if case let .signed(document)? = try? await call(.catalogue(Agentkeyring_V2_Empty())).result,
                let current = try? Sealing.verifiedCatalogue(document, members: existing.members, current: nil) {
                saved?.catalogueRevision = current.revision
            }
        } else {
            var members = Agentkeyring_V2_Members()
            members.domain = "agentkeyring.members.v2"
            members.revision = 1
            members.devices = [keys.device]
            members.machines = [keys.machine]
            members.relayTlsPublicKey = pin
            if let proof { members.setupProof = proof }
            let signed = try Sealing.signed(members.serializedData(), by: keys.deviceKeyID) { try keys.sign($0, context: context) }
            saved = Saved(endpoint: endpoint, pin: pin, members: try signed.serializedData(), catalogueRevision: 0)
            do {
                _ = try await call(.publishMembers(signed))
            } catch {
                saved = nil
                throw error
            }
            self.members = members
        }
        do {
            try await publish(context: context)
            try persist()
        } catch {
            if readSaved() == nil { saved = nil } // Kept if the catalogue went out and only the copies failed.
            throw error
        }
        start()
    }

    // MARK: Staying connected

    public func start() {
        guard saved != nil else {
            // The computer that stays on announces its relay instead of naming itself for a new iPhone.
            Task {
                hostsRelay = await announceIfRelayHere()
                if !hostsRelay { leaveDeviceInvitation() }
            }
            return
        }
        guard running == nil else { return leaveDeviceInvitation() }
        leaveDeviceInvitation()
        running = Task { [weak self] in
            while let self, !Task.isCancelled, let relay = self.relay {
                self.connection = .connecting
                do {
                    try await self.refreshMembers()
                    self.connection = .connected
                    DiagnosticLog.record("relay", "connected", ["members": "\(self.members?.revision ?? 0)"])
                    await self.refreshSelfTests()
                    await self.followCatalogue()
                    await self.recheckWaiting()
                    try await self.follow(relay)
                } catch is CancellationError {
                    return
                } catch {
                    deviceLogger.notice("Relay connection ended: \(String(describing: error), privacy: .public)")
                    DiagnosticLog.record("relay", "disconnected", ["reason": "\(error)"])
                }
                self.connection = .unreachable
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// A new stream sends only the requests still waiting, so one that ended
    /// while this Mac was disconnected would wait here for ever: ask for each.
    private func recheckWaiting() async {
        for id in waiting.keys {
            if case let .work(work)? = try? await call(.getWork(Self.reference(id))).result { receive(work) }
            else { waiting.removeValue(forKey: id) }
        }
    }

    private static func reference(_ id: String) -> Agentkeyring_V2_RequestReference {
        var reference = Agentkeyring_V2_RequestReference()
        reference.requestID = id
        return reference
    }

    private func receive(_ work: Agentkeyring_V2_Work) {
        // Only a request the computer it names signed: the relay can't make one up.
        guard let members, let request = try? Sealing.parseRequest(work.request) else { return }
        do { try Sealing.checkRequest(work, members: members, ownKeyID: keys.deviceKeyID) } catch {
            DiagnosticLog.record("work", "refused", ["request": request.requestID, "reason": "\(error)"])
            return
        }
        DiagnosticLog.record("work", "seen", ["request": request.requestID, "state": work.hasOutcome ? "\(work.outcome.state)" : "waiting"])
        // Not its own agents' requests, which it shows itself and passed on to the iPhone and Watch;
        // but Stop on one of them there ends the approval here.
        if request.machineID == keys.machineID {
            if work.hasOutcome, work.outcome.state == .ended, !work.outcome.endedBy.isEmpty,
               let leaseID = askedForAgents.first(where: { $0.value == request.requestID })?.key { onStoppedOnDevice?(leaseID) }
            return
        }
        if !request.loginID.isEmpty {
            onOtherComputersRequest?(request.requestID, request.loginID, .asked)
            switch work.hasOutcome ? work.outcome.state : .waiting {
            case .approved, .ended: onOtherComputersRequest?(request.requestID, request.loginID, .approved)
            case .denied: onOtherComputersRequest?(request.requestID, request.loginID, .denied)
            default: break
            }
        }
        if work.hasOutcome {
            waiting.removeValue(forKey: request.requestID)
            finished[request.requestID] = work
        } else {
            waiting[request.requestID] = work
        }
    }

    /// One connection for as long as it lasts: the requests, and Changes when
    /// the members list, the catalogue or the computers waiting to join change.
    /// The relay sends Changes at least every 30 seconds, so silence for 75
    /// means the connection died without closing.
    private func follow(_ relay: KeyringRelay) async throws {
        var request = Agentkeyring_V2_RelayRequest()
        request.method = .watchWork(Agentkeyring_V2_Empty())
        heard = .now
        let following = Task { @MainActor in
            try await relay.stream(request) { response in
                self.heard = .now
                self.connection = .connected
                switch response.result {
                case let .work(work)?: self.receive(work)
                case let .changes(changes)?: await self.take(changes)
                default: break
                }
            }
        }
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(15))
                if ContinuousClock.now - self.heard > .seconds(75) {
                    deviceLogger.notice("The relay went quiet for 75 seconds; connecting again.")
                    following.cancel()
                }
            }
        }
        defer { watchdog.cancel(); following.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await following.value
            } onCancel: {
                following.cancel()
            }
        } catch is CancellationError where !Task.isCancelled {
            throw RelayFailure(.unavailable, "The relay went quiet.") // The watchdog, not the app, ended it: connect again.
        }
    }

    @ObservationIgnored private var reportsRevision: UInt64 = 0
    /// This Mac runs the relay itself: it is the computer that stays on, not one he approves on.
    public private(set) var hostsRelay = false

    /// When this connection last heard from the relay.
    @ObservationIgnored private var heard = ContinuousClock.now

    private func take(_ changes: Agentkeyring_V2_Changes) async {
        joins = invited(changes.pendingJoins).filter { !hiddenJoins.contains(Self.joinID($0)) }
        if changes.membersRevision > members?.revision ?? 0 {
            DiagnosticLog.record("members", "changed", ["from": "\(members?.revision ?? 0)", "to": "\(changes.membersRevision)"])
            do { try await refreshMembers() } catch {
                deviceLogger.error("Could not take the new members list: \(String(describing: error), privacy: .public)")
            }
        }
        if changes.catalogueRevision > saved?.catalogueRevision ?? 0 { await followCatalogue() }
        if changes.reportsRevision != reportsRevision {
            reportsRevision = changes.reportsRevision
            await refreshSelfTests()
        }
    }

    /// Takes rule changes made on another device.
    func followCatalogue() async {
        guard let members, let saved, let response = try? await call(.catalogue(Agentkeyring_V2_Empty())),
            case let .signed(document) = response.result,
            let catalogue = try? Sealing.verifiedCatalogue(document, members: members, current: nil),
            catalogue.revision > saved.catalogueRevision, document.signerKeyID != keys.deviceKeyID else { return }
        let mine = (try? await call(.automaticLogins(Agentkeyring_V2_Empty())))?.sealedLogins.logins
            .filter { $0.openerID == keys.machineID } ?? []
        self.saved?.catalogueRevision = catalogue.revision
        try? persist()
        await onCatalogue?(catalogue, mine)
    }

    /// Each device's latest status report, checked against its key: its first-run step, its checklist.
    private func refreshSelfTests() async {
        guard let members, let response = try? await call(.selfTests(Agentkeyring_V2_Empty())) else { return }
        for document in response.selfTests.reports {
            guard let signer = try? Sealing.verify(document, members: members, allowReplyKey: true),
                let report = try? Agentkeyring_V2_SelfTestReport(serializedBytes: document.payload),
                report.deviceKeyID == signer.keyID else { continue }
            reports[signer.keyID] = report
        }
        await onDevicesChanged?()
    }

    /// Each device's latest status report, by device key.
    public private(set) var reports: [String: Agentkeyring_V2_SelfTestReport] = [:]
    /// A device joined, or one's status report changed: first run's windows may move on.
    @ObservationIgnored var onDevicesChanged: (@MainActor () async -> Void)?
    /// A request from an agent on another computer, and Josh's answer: for the counts per password.
    @ObservationIgnored var onOtherComputersRequest: ((String, String, PasswordUsageLog.Event) -> Void)?

    /// Every revision since ours, each checked against the one before: a
    /// later one may be signed by a device this Mac has not seen sign yet.
    private func refreshMembers() async throws {
        guard var current = members else { return }
        let response = try await call(.membersSince(current.revision))
        var latest: Data?
        for document in response.membersChain.revisions {
            guard let next = try? Sealing.verifiedMembers(document, current: current) else { break }
            current = next
            latest = try document.serializedData()
        }
        guard let latest else { return }
        members = current
        saved?.members = latest
        try persist()
        await onDevicesChanged?()
    }

    /// The joins that prove one of this Mac's invitations. If two different
    /// joiners prove the same one, the secret has leaked: neither is shown,
    /// and the invitation is withdrawn.
    private func invited(_ pending: [Agentkeyring_V2_PendingJoin]) -> [Agentkeyring_V2_PendingJoin] {
        invitations = invitations.filter { $0.value > .now }
        var bySecret: [Data: [Agentkeyring_V2_PendingJoin]] = [:]
        for join in pending {
            if let secret = invitations.keys.first(where: { Sealing.joinProof(secret: $0, joining: join.request) == join.request.proof }) {
                bySecret[secret, default: []].append(join)
            }
        }
        var shown: [Agentkeyring_V2_PendingJoin] = []
        for (secret, joins) in bySecret {
            if Set(joins.map(Self.joinID)).count > 1 {
                deviceLogger.error("Two joiners proved the same invitation; it is withdrawn and neither is shown.")
                invitations.removeValue(forKey: secret)
            } else {
                shown += joins
            }
        }
        return shown
    }

    /// A one-time link for one machine to join, valid for ten minutes, for an
    /// agent to pass to 'agent-keyring enrol --invite' over SSH.
    public func inviteMachine() throws -> String {
        "agentkeyring://join?invite=" + (try invitation(lasting: 600).serializedData()).base64URLEncoded
    }

    private func invitation(lasting seconds: TimeInterval) throws -> Agentkeyring_V2_JoinInvite {
        if let saved { return invitation(endpoint: saved.endpoint, pin: saved.pin, lasting: seconds) }
        // While the always-on machine is being set up, others may join too.
        guard let setup else { throw RelayFailure(.unavailable, "Connect this Mac to the relay first: agent-keyring setup-relay.") }
        return invitation(endpoint: setup.endpoint, pin: setup.pin, lasting: seconds)
    }

    private func invitation(endpoint: RelayEndpoint, pin: Data, lasting seconds: TimeInterval) -> Agentkeyring_V2_JoinInvite {
        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let expires = Date.now.addingTimeInterval(seconds)
        invitations[secret] = expires
        var invite = Agentkeyring_V2_JoinInvite()
        invite.relayHost = endpoint.host
        invite.relayPort = UInt32(endpoint.port)
        invite.relayTlsSha256 = Sealing.sha256(pin)
        invite.inviterKeyID = keys.deviceKeyID
        invite.inviterLabel = keys.device.label
        invite.secret = secret
        invite.expiresUnixSeconds = Int64(expires.timeIntervalSince1970)
        return invite
    }

    /// Leaves an invitation for a new iPhone in iCloud Keychain, where only
    /// Agent Keyring's own apps on Josh's devices can read it. Replaced at
    /// each launch and after each device joins.
    private var invitationItem: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: true,
         kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringSharedKeychainGroup") as? String ?? "",
         kSecAttrService as String: "com.joshpalmer.AgentKeyring.invitation", kSecAttrAccount as String: "relay"]
    }

    /// Keeps an invitation for a new iPhone in iCloud Keychain, where only
    /// Agent Keyring's own apps on Josh's devices can read it. The one there
    /// is kept while it is this Mac's and unexpired; a new one replaces it
    /// after a device joins, or when there is none. Before there is a computer
    /// that stays on, it names only this Mac, so the iPhone can say this Mac is
    /// set up and what it still needs.
    func leaveDeviceInvitation(endpoint: RelayEndpoint? = nil, pin: Data? = nil, replacing: Bool = false) {
        guard let endpoint = endpoint ?? saved?.endpoint, let pin = pin ?? saved?.pin else { return leaveName() }
        var query = invitationItem
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        if !replacing, SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let bytes = found as? Data,
            let current = try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes), current.inviterKeyID == keys.deviceKeyID,
            current.relayTlsSha256 == Sealing.sha256(pin), current.expiresUnixSeconds > Int64(Date().timeIntervalSince1970) + 86400 {
            invitations[current.secret] = Date(timeIntervalSince1970: TimeInterval(current.expiresUnixSeconds))
            return
        }
        guard let value = try? invitation(endpoint: endpoint, pin: pin, lasting: 7 * 86400).serializedData() else { return }
        SecItemDelete(invitationItem as CFDictionary)
        var item = invitationItem
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { deviceLogger.notice("Left an invitation for a new iPhone in iCloud Keychain.") }
        else { deviceLogger.error("Could not leave the iPhone's invitation in iCloud Keychain: \(status, privacy: .public)") }
    }

    /// An invitation with no relay: this Mac's name and key only. A real one is never replaced by it.
    private func leaveName() {
        var query = invitationItem
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let bytes = found as? Data,
            let current = try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes), current.inviterKeyID == keys.deviceKeyID {
            return
        }
        var invite = Agentkeyring_V2_JoinInvite()
        invite.inviterKeyID = keys.deviceKeyID
        invite.inviterLabel = keys.device.label
        guard let value = try? invite.serializedData() else { return }
        SecItemDelete(invitationItem as CFDictionary)
        var item = invitationItem
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { deviceLogger.notice("Left this Mac's name for a new iPhone in iCloud Keychain.") }
        else { deviceLogger.error("Could not leave this Mac's name in iCloud Keychain: \(status, privacy: .public)") }
    }

    public static func joinID(_ join: Agentkeyring_V2_PendingJoin) -> String {
        switch join.request.joining {
        case let .machine(machine)?: machine.machineID
        case let .device(device)?: device.keyID
        case nil: ""
        }
    }

    // MARK: Answering requests from other machines

    /// Approves after Josh's Touch ID: opens the one login with this Mac's chip
    /// key and seals it again for the machine that asked.
    public func approve(_ requestID: String, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        guard let work = waiting[requestID], let members else { throw RelayFailure(.notFound, "This request is no longer waiting.") }
        let request = try Sealing.parseRequest(work.request)
        if isPractice(work) { return try await approvePractice(work, context: context, onAuthenticated: onAuthenticated) }
        guard let asking = try? Sealing.checkRequest(work, members: members, ownKeyID: keys.deviceKeyID) else {
            throw RelayFailure(.permissionDenied, "The computer that asked is not one of yours.")
        }
        guard let login = try await catalogueLogins().first(where: { $0.loginID == request.loginID }), login.rule != .blocked else {
            throw RelayFailure(.permissionDenied, "This password is blocked for agents.")
        }
        guard let copy = try await store.sealed().first(where: { $0.loginID == request.loginID && $0.openerID == keys.deviceKeyID }) else {
            throw RelayFailure(.permissionDenied, "This Mac has no copy of this password. Copy your passwords again from Passwords.")
        }
        let reason = ApprovalSentence.lease(site: login.sites.first ?? login.title,
            account: login.account.isEmpty ? login.title : login.account, agent: request.agent, machine: asking.label)
        try await confirm(context, reason: reason, until: Date(timeIntervalSince1970: TimeInterval(request.answerByUnixSeconds)))
        try keys.check(copy, members: members)
        let secret = try keys.open(copy, context: context)
        // Only the password shown: the relay and the files on disk are not trusted to say which it is.
        try Sealing.checkBound(secret, title: login.title, sites: login.sites, account: login.account)
        let receiving = try P256.KeyAgreement.PublicKey(x963Representation: asking.receivingPublicKey)
        let upload = try Sealing.approve(request: work.request, secret: secret, sites: login.sites, receivingKey: receiving,
            signerKeyID: keys.deviceKeyID) { try keys.sign($0, context: context) }
        onAuthenticated()
        _ = try await call(.answer(upload))
        waiting.removeValue(forKey: requestID)
    }

    /// A practice request sent to this Mac from the iPhone or Devices: it names
    /// this Mac's own device key and no password.
    public func isPractice(_ work: Agentkeyring_V2_Work) -> Bool {
        (try? Sealing.parseRequest(work.request))?.forDeviceKeyID == keys.deviceKeyID
    }

    /// Approved with Touch ID, as a real one: a signed answer with nothing delivered.
    private func approvePractice(_ work: Agentkeyring_V2_Work, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        try await confirm(context, reason: "use a practice password for example.com, you@example.com")
        var answer = Agentkeyring_V2_Answer()
        answer.domain = "agentkeyring.answer.v2"
        answer.requestSha256 = Sealing.sha256(work.request)
        answer.choice = .approve
        answer.decidedUnixSeconds = Int64(Date().timeIntervalSince1970)
        answer.notAfterUnixSeconds = answer.decidedUnixSeconds + 60
        var upload = Agentkeyring_V2_AnswerUpload()
        upload.answer = try Sealing.signed(answer.serializedData(), by: keys.deviceKeyID) { try keys.sign($0, context: context) }
        onAuthenticated()
        _ = try await call(.answer(upload))
        let id = (try? Sealing.parseRequest(work.request))?.requestID ?? ""
        DiagnosticLog.record("practice", "approved", ["request": id])
        waiting.removeValue(forKey: id)
    }

    /// Denies; words are signed with the reply key, which needs no Touch ID.
    public func deny(_ requestID: String, reply: String) async throws {
        guard let work = waiting[requestID] else { throw RelayFailure(.notFound, "This request is no longer waiting.") }
        let upload = reply.isEmpty ? Sealing.plainDeny(requestID: requestID)
            : try Sealing.deny(request: work.request, reply: reply, signerKeyID: keys.replyKeyID) { try keys.signReply($0) }
        _ = try await call(.answer(upload))
        waiting.removeValue(forKey: requestID)
    }

    /// macOS's own dialog, with our sentence after "Agent Keyring is trying to".
    func confirm(_ context: LAContext, reason: String, until deadline: Date = .now.addingTimeInterval(600)) async throws {
        try await OwnerConfirmation.confirm(context, reason: reason, until: deadline)
        try Task.checkCancellation()
    }

    /// The sentence for approving a join, after "Agent Keyring is trying to".
    public func joinReason(_ id: String) -> String {
        switch joins.first(where: { Self.joinID($0) == id })?.request.joining {
        case let .machine(machine)?: "add \(machine.label)"
        case let .device(device)?: "add \(device.label)"
        case nil: "add a device"
        }
    }

    /// Tells the relay what this Mac's own test found, signed by its reply key.
    /// This Mac's status report, signed by its reply key: where it is in the
    /// journey, the journey's steps for the devices he chose, and its practice
    /// result. Sent on every step change; the relay passes the change on.
    func reportStatus(_ firstRun: FirstRun, practice: (passed: Bool, error: String)?) async {
        guard isJoined else { return }
        var report = Agentkeyring_V2_SelfTestReport()
        report.domain = "agentkeyring.selftest.v2"
        report.deviceKeyID = keys.deviceKeyID
        report.testedUnixSeconds = Int64(Date().timeIntervalSince1970)
        if let practice {
            var check = Agentkeyring_V2_SelfTestCheck()
            check.name = "test request"
            check.passed = practice.passed
            check.error = practice.error
            report.checks = [check]
        }
        report.journey = firstRun.journey.map(\.wire)
        report.step = firstRun.step.wire
        report.finished = firstRun == .finished
        do {
            let signed = try Sealing.signed(report.serializedData(), by: keys.replyKeyID) { try keys.signReply($0) }
            _ = try await call(.reportSelfTest(signed))
        } catch {
            deviceLogger.error("Could not send this Mac's status report: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Asking the iPhone or Watch, as a machine

    /// What the iPhone or Watch decided about a request from an agent on this Mac.
    public enum DeviceAnswer {
        case approved(Agentkeyring_V2_DeliveryContents)
        case denied(reply: String)
        case unanswered
        case cancelled
    }

    /// An agent on this Mac asked: this Mac writes and signs the request as
    /// the machine it also is, so the iPhone and Watch can answer it too,
    /// waits for the answer, and opens the delivery with its receiving key.
    public func askDevices(leaseID: String, loginID: String, reason: String, agent: String, project: String, task: String) async throws -> DeviceAnswer {
        guard let relay, let members else {
            throw RelayFailure(.unavailable, "This Mac is not connected to your iPhone or Apple Watch.")
        }
        var ask = Agentkeyring_V2_Request()
        ask.domain = "agentkeyring.request.v2"
        ask.requestID = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        ask.loginID = loginID
        ask.machineID = keys.machineID
        ask.reason = reason
        ask.agent = agent
        ask.project = project
        ask.task = task
        ask.askedUnixSeconds = Int64(Date().timeIntervalSince1970)
        ask.answerByUnixSeconds = ask.askedUnixSeconds + 600
        let requestBytes = try ask.serializedData()
        let signed = try Sealing.signed(requestBytes, by: keys.machineID) { try keys.tls.sign($0) }
        askedForAgents[leaseID] = ask.requestID
        DiagnosticLog.record("devices", "asked", ["lease": leaseID, "request": ask.requestID, "login": loginID])
        let asked = try await call(.askSigned(signed))
        var request = Agentkeyring_V2_RelayRequest()
        let reference = Self.reference(ask.requestID)
        request.method = .watch(reference)
        var final = asked.lease
        if final.state == .waiting {
            try await relay.stream(request) { response in
                if case let .lease(lease) = response.result { final = lease }
            }
        }
        // The answer may come from a device that joined after the request was
        // made, such as an Apple Watch added on the iPhone: check it against
        // the members list as it is now.
        try? await refreshMembers()
        let current = self.members ?? members
        DiagnosticLog.record("devices", "answered", ["request": ask.requestID, "state": "\(final.state)", "by": final.answeredBy])
        // Answered in this Mac's own panel: there is nothing to collect.
        if final.answeredBy == current.machines.first(where: { $0.machineID == keys.machineID })?.label { return .cancelled }
        switch final.state {
        case .approved:
            let approval = try await call(.collect(reference)).approval
            guard approval.request == requestBytes else { throw RelayFailure(.permissionDenied, "The relay returned an answer to another request.") }
            return .approved(try Sealing.openDelivery(approval, members: current, with: keys.receiving))
        case .denied:
            let approval = try? await call(.collect(reference)).approval
            let reply = approval.flatMap { $0.request == requestBytes ? try? Sealing.verifiedAnswer($0, members: current).reply : nil } ?? ""
            return .denied(reply: reply)
        case .unanswered: return .unanswered
        default: return .cancelled
        }
    }

    /// The relay's recent lines and each device's latest log, for `agent-keyring logs`.
    public func relayLogs(since: Int64, request: String) async throws -> [String] {
        var logs = Agentkeyring_V2_LogsRequest()
        logs.sinceUnixSeconds = since
        logs.requestID = request
        return try await call(.logs(logs)).logs.lines
    }

    /// A practice request on another device of Josh's (Test in Devices): it
    /// arrives there like a real one, and this ends when that device answers.
    /// `progress` hears each step on the way (sent, with Apple, arrived). A
    /// dropped connection is still waiting: the same request is rejoined by
    /// its id, never made again.
    public func practice(on deviceKeyID: String, progress: @MainActor (Agentkeyring_V2_Lease) -> Void) async throws -> Agentkeyring_V2_Lease {
        guard deviceKeyID != keys.deviceKeyID else {
            throw RelayFailure(.unavailable, "This Mac is not connected to your iPhone or Apple Watch.")
        }
        var test = Agentkeyring_V2_TestRequest()
        test.forDeviceKeyID = deviceKeyID
        test.requestID = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        var request = Agentkeyring_V2_RelayRequest()
        request.method = .testRequest(test)
        let giveUp = ContinuousClock.now + .seconds(660)
        DiagnosticLog.record("practice", "sent", ["request": test.requestID, "device": deviceKeyID.prefix(16).description])
        var last = Agentkeyring_V2_Lease()
        while true {
            guard let relay else { throw RelayFailure(.unavailable, "This Mac is not connected to your iPhone or Apple Watch.") }
            do {
                try await relay.stream(request) { response in
                    guard case let .lease(lease) = response.result else { return }
                    last = lease
                    progress(lease)
                }
                if last.state != .waiting { break }
            } catch where ContinuousClock.now < giveUp && !Task.isCancelled {
                DiagnosticLog.record("practice", "rejoining", ["request": test.requestID, "reason": "\(error)"])
                try await Task.sleep(for: .seconds(2))
            }
        }
        DiagnosticLog.record("practice", "answered", ["request": test.requestID, "state": "\(last.state)"])
        return last
    }

    /// The agent stopped asking, or its approval ended: the iPhone and Watch
    /// show the request as ended. With `answeredHere` ("approved" or "denied"),
    /// this Mac answered it itself, and the devices show that instead.
    public func stopAsking(_ clientRequestID: String, answeredHere: String = "") async {
        guard let id = askedForAgents[clientRequestID] else { return }
        var reference = Self.reference(id)
        reference.answeredHere = answeredHere
        _ = try? await call(.end(reference))
    }

    /// Stop on the iPhone or Watch, for an approval this Mac gave its own agent: the lease ID.
    @ObservationIgnored public var onStoppedOnDevice: ((String) -> Void)?

    public func forget(_ clientRequestID: String) { askedForAgents.removeValue(forKey: clientRequestID) }

    // MARK: Machines and devices joining

    /// Lets a computer or device join, after Josh's Touch ID. It is in the
    /// members list at once, so the iPhone moves on in seconds. A new device
    /// then gets a copy of every password, opened here with the same approval
    /// and sealed again for it off the main thread, in batches it can count.
    /// A computer gets no Automatic passwords yet.
    public func approveJoin(_ id: String, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        guard var next = members, let join = joins.first(where: { Self.joinID($0) == id }) else {
            throw RelayFailure(.notFound, "Nothing is waiting to join with that name.")
        }
        try await confirm(context, reason: joinReason(id))
        onAuthenticated()
        var newDevice: Agentkeyring_V2_Device?
        switch join.request.joining {
        case var .machine(machine)?:
            machine.automaticAllowed = false
            next.machines.removeAll { $0.machineID == machine.machineID }
            next.machines.append(machine)
        case let .device(device)?:
            next.devices.removeAll { $0.keyID == device.keyID }
            next.devices.append(device)
            newDevice = device
        case nil:
            return
        }
        try await publishMembers(next, context: context)
        joins.removeAll { Self.joinID($0) == id }
        if let secret = invitations.keys.first(where: { Sealing.joinProof(secret: $0, joining: join.request) == join.request.proof }) {
            invitations.removeValue(forKey: secret)
        }
        guard let newDevice else { return }
        Task {
            do { try await fill(newDevice, context: context) } catch {
                DiagnosticLog.record("devices", "fill-failed", ["device": newDevice.label, "reason": "\(error)"])
            }
        }
    }

    /// A new device being given its copies: Josh sees how far it has got.
    public struct Filling: Equatable, Sendable {
        public let deviceKeyID: String
        public let label: String
        public var done: Int
        public let total: Int
    }

    public private(set) var filling: Filling?

    private func fill(_ device: Agentkeyring_V2_Device, context: LAContext) async throws {
        guard let members else { return }
        let key = try P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)
        let mine = try await store.sealed().filter { $0.openerID == keys.deviceKeyID }
        let resealer = try keys.resealer(context: context, members: members)
        filling = Filling(deviceKeyID: device.keyID, label: device.label, done: 0, total: mine.count)
        defer { filling = nil }
        DiagnosticLog.record("devices", "filling", ["device": device.label, "passwords": "\(mine.count)"])
        let started = ContinuousClock.now
        for start in stride(from: 0, to: mine.count, by: 50) {
            let batch = Array(mine[start..<min(start + 50, mine.count)])
            let sealed = try await Task.detached { try batch.map { try resealer.reseal($0, to: key, openerID: device.keyID) } }.value
            try await store.replaceSealed(try await store.sealed().filter { $0.openerID != device.keyID || !sealed.map(\.loginID).contains($0.loginID) } + sealed)
            var upload = Agentkeyring_V2_SealedLogins()
            upload.logins = sealed
            _ = try await call(.publishSealedLogins(upload))
            filling?.done = start + batch.count
        }
        DiagnosticLog.record("devices", "filled", ["device": device.label, "passwords": "\(mine.count)",
            "seconds": "\((ContinuousClock.now - started).components.seconds)"])
    }

    /// Josh denied a computer: the agent waiting on its enrol hears at once,
    /// with his words, and its invitation is withdrawn. A device, or a
    /// computer whose command cannot be refused, is only hidden. True if the
    /// relay took the denial.
    public func refuseJoin(_ id: String, reply: String) async -> Bool {
        defer { hideJoin(id) }
        guard let join = joins.first(where: { Self.joinID($0) == id }), case let .machine(machine)? = join.request.joining,
            !join.request.refusalKeySha256.isEmpty,
            let secret = invitations.keys.first(where: { Sealing.joinProof(secret: $0, joining: join.request) == join.request.proof })
        else { return false }
        invitations.removeValue(forKey: secret)
        do {
            _ = try await call(.refuseJoin(Self.refusal(machineID: machine.machineID, secret: secret, reply: reply)))
            return true
        } catch {
            deviceLogger.error("Could not tell \(machine.label, privacy: .public) it was denied: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The relay lets the request run out after ten minutes.
    public func hideJoin(_ id: String) {
        hiddenJoins.insert(id)
        joins.removeAll { Self.joinID($0) == id }
    }

    /// Removes a machine or another device, after Josh's Touch ID.
    public func remove(_ id: String, context: LAContext) async throws {
        guard var next = members else { return }
        next.machines.removeAll { $0.machineID == id }
        next.devices.removeAll { $0.keyID == id && $0.keyID != keys.deviceKeyID }
        try await publishMembers(next, context: context)
        try await store.replaceSealed(try await store.sealed().filter { $0.openerID != id })
    }

    /// Switches computers on or off for Automatic passwords in a new signed
    /// list of members, with a context Josh has just approved. The model seals
    /// the passwords themselves and then calls `sendCopies`.
    func setAutomatic(_ changes: [String: Bool], context: LAContext) async throws {
        guard let members else { return }
        var next = members
        for index in next.machines.indices {
            if let allowed = changes[next.machines[index].machineID] { next.machines[index].automaticAllowed = allowed }
        }
        guard next != members else { return }
        try await publishMembers(next, context: context)
    }

    /// Replaces at the relay every copy sealed to these computers with the ones held here.
    func sendCopies(for machineIDs: Set<String>) async throws {
        guard isJoined, !machineIDs.isEmpty else { return }
        var batch = Agentkeyring_V2_SealedLogins()
        batch.clearedOpeners = machineIDs.sorted()
        batch.logins = try await store.sealed().filter { machineIDs.contains($0.openerID) }
        _ = try await call(.publishSealedLogins(batch))
    }

    /// Removes a machine or device; the system dialog is the confirmation.
    public func removeConfirmed(_ id: String, context: LAContext) async throws {
        let label = members?.machines.first { $0.machineID == id }?.label ?? members?.devices.first { $0.keyID == id }?.label ?? "it"
        try await confirm(context, reason: "remove \(label)")
        try await remove(id, context: context)
    }

    private func publishMembers(_ next: Agentkeyring_V2_Members, context: LAContext) async throws {
        var next = next
        next.revision = (members?.revision ?? 0) + 1
        let signed = try Sealing.signed(next.serializedData(), by: keys.deviceKeyID) { try keys.sign($0, context: context) }
        _ = try await call(.publishMembers(signed))
        members = next
        saved?.members = try signed.serializedData()
        try persist()
    }

    // MARK: Publishing logins

    /// Signs the catalogue with Touch ID and sends it, with the sealed copies
    /// for the other devices and machines. This Mac's own copies stay here.
    public func publish(context: LAContext, withdrawn: Set<String> = []) async throws {
        guard var saved else { return }
        var catalogue = Agentkeyring_V2_Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = saved.catalogueRevision + 1
        catalogue.logins = try await catalogueLogins()
        catalogue.importedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signed = try Sealing.signed(catalogue.serializedData(), by: keys.deviceKeyID) { try keys.sign($0, context: context) }
        _ = try await call(.publishCatalogue(signed))
        saved.catalogueRevision = catalogue.revision
        self.saved = saved
        try persist()
        let others = Set((members?.devices.map(\.keyID) ?? []) + (members?.machines.map(\.machineID) ?? []))
            .subtracting([keys.deviceKeyID])
        try await publishSealed(for: others, withdrawn: withdrawn)
    }

    private func publishSealed(for openers: Set<String>, withdrawn: Set<String> = []) async throws {
        var batch = Agentkeyring_V2_SealedLogins()
        batch.logins = try await store.sealed().filter { openers.contains($0.openerID) && !withdrawn.contains($0.loginID) }
        batch.withdrawnLoginIds = withdrawn.sorted()
        guard !batch.logins.isEmpty || !batch.withdrawnLoginIds.isEmpty else { return }
        _ = try await call(.publishSealedLogins(batch))
    }

    /// The other openers each login must be sealed to: devices' opening keys,
    /// and machines allowed Automatic logins for those that are Automatic.
    public func otherOpeners(automatic: Bool) -> [(id: String, key: P256.KeyAgreement.PublicKey)] {
        guard let members else { return [] }
        let devices = members.devices.filter { $0.keyID != keys.deviceKeyID }.compactMap { device in
            (try? P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)).map { (device.keyID, $0) }
        }
        guard automatic else { return devices }
        return devices + members.machines.filter { $0.automaticAllowed && $0.machineID != keys.machineID }.compactMap { machine in
            (try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)).map { (machine.machineID, $0) }
        }
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
