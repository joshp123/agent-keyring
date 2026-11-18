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
    }

    public private(set) var connection = Connection.notSetUp
    /// Set by an agent's `agent-keyring setup-relay`: Josh confirms in a panel before anything is signed.
    public private(set) var setupWaiting: RelayEndpoint?
    /// Requests from agents on other machines that nobody has answered yet.
    public private(set) var waiting: [String: Agentkeyring_V2_Work] = [:]
    /// Requests answered here or elsewhere, newest outcome last, for the menu bar.
    public private(set) var finished: [String: Agentkeyring_V2_Work] = [:]
    public private(set) var joins: [Agentkeyring_V2_PendingJoin] = []
    public private(set) var members: Agentkeyring_V2_Members?

    let keys: MacKeys
    let store: LoginStore
    /// The logins and their rules as the catalogue, from the app's import and rules.
    let catalogueLogins: @MainActor () async throws -> [Agentkeyring_V2_Login]
    private var saved: Saved?
    private var setupPin: Data?
    private var hiddenJoins = Set<String>()
    /// Invitations this Mac issued and nobody has used: secret, expiry. A join
    /// is shown only if its proof checks against one of them.
    private var invitations: [Data: Date] = [:]
    @ObservationIgnored private var running: Task<Void, Never>?
    private let file = URL.applicationSupportDirectory.appending(path: "AgentKeyring/relay-v2.plist")

    init(keys: MacKeys, store: LoginStore, catalogueLogins: @escaping @MainActor () async throws -> [Agentkeyring_V2_Login]) {
        self.keys = keys
        self.store = store
        self.catalogueLogins = catalogueLogins
        if let bytes = try? Data(contentsOf: file), let saved = try? PropertyListDecoder().decode(Saved.self, from: bytes) {
            self.saved = saved
            members = Self.parse(saved.members)
        }
    }

    public var isJoined: Bool { saved != nil }
    /// The waiting requests, read from their bytes.
    public var waitingRequests: [Agentkeyring_V2_Request] { waiting.values.compactMap { try? Sealing.parseRequest($0.request) } }
    public var ownMachineID: String { keys.machineID }

    private static func parse(_ signed: Data) -> Agentkeyring_V2_Members? {
        guard let document = try? Agentkeyring_V2_Signed(serializedBytes: signed) else { return nil }
        return try? Agentkeyring_V2_Members(serializedBytes: document.payload)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(saved).write(to: file, options: .atomic)
    }

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

    /// An agent ran `agent-keyring setup-relay`: note the relay's key and ask Josh.
    public func beginSetup(_ endpoint: RelayEndpoint) async throws {
        var observed = Data()
        var request = Agentkeyring_V2_RelayRequest()
        request.method = .members(Agentkeyring_V2_Empty())
        _ = try? await KeyringRelay(endpoint: endpoint, identity: keys.tls, pin: nil).call(request) { observed = $0 }
        guard !observed.isEmpty else { throw RelayFailure(.unavailable, "The relay could not be reached at \(endpoint.host).") }
        setupPin = observed
        setupWaiting = endpoint
    }

    public func abandonSetup() { setupWaiting = nil; setupPin = nil }

    /// Josh confirmed with Touch ID: this Mac becomes the first device, and the
    /// machine its own agents run on, at this relay.
    public func confirmSetup(context: LAContext) async throws {
        guard let endpoint = setupWaiting, let pin = setupPin else { return }
        var members = Agentkeyring_V2_Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [keys.device]
        members.machines = [keys.machine]
        members.relayTlsPublicKey = pin
        let signed = try Sealing.signed(members.serializedData(), by: keys.deviceKeyID) { try keys.sign($0, context: context) }
        saved = Saved(endpoint: endpoint, pin: pin, members: try signed.serializedData(), catalogueRevision: 0)
        do {
            _ = try await call(.publishMembers(signed))
        } catch {
            saved = nil
            throw error
        }
        self.members = members
        try persist()
        setupWaiting = nil
        try await publish(context: context)
        start()
    }

    // MARK: Staying connected

    public func start() {
        guard saved != nil, running == nil else { return }
        if invitations.isEmpty { leaveDeviceInvitation() }
        running = Task { [weak self] in
            while let self, !Task.isCancelled, let relay = self.relay {
                self.connection = .connecting
                do {
                    try await self.refreshMembers()
                    self.connection = .connected
                    var request = Agentkeyring_V2_RelayRequest()
                    request.method = .watchWork(Agentkeyring_V2_Empty())
                    let joins = Task { await self.pollJoins() }
                    defer { joins.cancel() }
                    try await relay.stream(request) { response in
                        self.connection = .connected
                        if case let .work(work) = response.result { self.receive(work) }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    deviceLogger.notice("Relay connection ended: \(String(describing: error), privacy: .public)")
                }
                self.connection = .unreachable
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func receive(_ work: Agentkeyring_V2_Work) {
        guard let request = try? Sealing.parseRequest(work.request) else { return }
        if work.hasOutcome {
            waiting.removeValue(forKey: request.requestID)
            finished[request.requestID] = work
        } else {
            waiting[request.requestID] = work
        }
    }

    /// Also notices a connection that died without closing, since the work
    /// stream itself is silent while nothing waits.
    private func pollJoins() async {
        while !Task.isCancelled {
            do {
                let response = try await call(.pendingJoins(Agentkeyring_V2_Empty()))
                joins = invited(response.pendingJoins.joins).filter { !hiddenJoins.contains(Self.joinID($0)) }
            } catch {
                guard !Task.isCancelled else { return }
                running?.cancel()
                running = nil
                connection = .unreachable
                try? await Task.sleep(for: .seconds(5))
                start()
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refreshMembers() async throws {
        let response = try await call(.members(Agentkeyring_V2_Empty()))
        guard case let .signed(document) = response.result, let current = members,
            let newer = try? Sealing.verifiedMembers(document, current: current) else { return }
        members = newer
        saved?.members = try document.serializedData()
        try persist()
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
        guard let saved else { throw RelayFailure(.unavailable, "Connect this Mac to the relay first: agent-keyring setup-relay.") }
        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let expires = Date.now.addingTimeInterval(seconds)
        invitations[secret] = expires
        var invite = Agentkeyring_V2_JoinInvite()
        invite.relayHost = saved.endpoint.host
        invite.relayPort = UInt32(saved.endpoint.port)
        invite.relayTlsSha256 = Sealing.sha256(saved.pin)
        invite.inviterKeyID = keys.deviceKeyID
        invite.secret = secret
        invite.expiresUnixSeconds = Int64(expires.timeIntervalSince1970)
        return invite
    }

    /// Leaves an invitation for a new iPhone in iCloud Keychain, where only
    /// Agent Keyring's own apps on Josh's devices can read it. Replaced at
    /// each launch and after each device joins.
    func leaveDeviceInvitation() {
        guard let invite = try? invitation(lasting: 7 * 86400), let value = try? invite.serializedData() else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true, kSecAttrAccessGroup as String: "7M8BR7R488.com.joshpalmer.AgentKeyring.shared",
            kSecAttrService as String: "com.joshpalmer.AgentKeyring.invitation", kSecAttrAccount as String: "relay"]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { deviceLogger.error("Could not leave the iPhone's invitation in iCloud Keychain: \(status, privacy: .public)") }
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
        guard let asking = members.machines.first(where: { $0.machineID == request.machineID }) else {
            throw RelayFailure(.permissionDenied, "The machine that asked is not one of yours.")
        }
        guard let login = try await catalogueLogins().first(where: { $0.loginID == request.loginID }), login.rule != .blocked else {
            throw RelayFailure(.permissionDenied, "This login is blocked for agents.")
        }
        guard let copy = try await store.sealed().first(where: { $0.loginID == request.loginID && $0.openerID == keys.deviceKeyID }) else {
            throw RelayFailure(.permissionDenied, "This Mac cannot open this login. Approve it on your iPhone or Watch.")
        }
        let reason = ApprovalSentence.lease(site: login.sites.first ?? login.title,
            account: login.account.isEmpty ? login.title : login.account, agent: request.agent, machine: asking.label)
        try await confirm(context, reason: reason, until: Date(timeIntervalSince1970: TimeInterval(request.answerByUnixSeconds)))
        let secret = try keys.open(copy, context: context)
        let receiving = try P256.KeyAgreement.PublicKey(x963Representation: asking.receivingPublicKey)
        let upload = try Sealing.approve(request: work.request, secret: secret, sites: login.sites, receivingKey: receiving,
            signerKeyID: keys.deviceKeyID) { try keys.sign($0, context: context) }
        onAuthenticated()
        _ = try await call(.answer(upload))
        waiting.removeValue(forKey: requestID)
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
    public func joinReason(_ id: String, allowAutomatic: Bool) -> String {
        switch joins.first(where: { Self.joinID($0) == id })?.request.joining {
        case let .machine(machine)?:
            allowAutomatic ? "add \(machine.label) as your always-on machine" : "add \(machine.label) as a machine that asks for your logins"
        case let .device(device)?: "let \(device.label) approve requests"
        case nil: "add a device"
        }
    }

    // MARK: Machines and devices joining

    /// Lets a machine or device join, after Josh's Touch ID. A machine allowed
    /// Automatic logins gets its own sealed copy of each; a new device gets a
    /// copy of every login, opened here with the same approval.
    public func approveJoin(_ id: String, allowAutomatic: Bool, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        guard var next = members, let join = joins.first(where: { Self.joinID($0) == id }) else {
            throw RelayFailure(.notFound, "Nothing is waiting to join with that name.")
        }
        try await confirm(context, reason: joinReason(id, allowAutomatic: allowAutomatic))
        onAuthenticated()
        var sealed = try await store.sealed()
        switch join.request.joining {
        case var .machine(machine)?:
            machine.automaticAllowed = allowAutomatic
            next.machines.removeAll { $0.machineID == machine.machineID }
            next.machines.append(machine)
            if allowAutomatic {
                let key = try P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)
                for copy in sealed where copy.openerID == keys.machineID {
                    sealed.append(try Sealing.seal(try Sealing.open(copy, with: keys.receiving), to: key, openerID: machine.machineID))
                }
            }
        case let .device(device)?:
            next.devices.removeAll { $0.keyID == device.keyID }
            next.devices.append(device)
            let key = try P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)
            for copy in sealed where copy.openerID == keys.deviceKeyID {
                sealed.append(try Sealing.seal(try keys.open(copy, context: context), to: key, openerID: device.keyID))
            }
        case nil:
            return
        }
        try await publishMembers(next, context: context)
        try await store.replaceSealed(sealed)
        try await publishSealed(for: [id])
        joins.removeAll { Self.joinID($0) == id }
        if let secret = invitations.keys.first(where: { Sealing.joinProof(secret: $0, joining: join.request) == join.request.proof }) {
            invitations.removeValue(forKey: secret)
        }
        if case .device? = join.request.joining { leaveDeviceInvitation() }
    }

    /// "Not now": the relay lets the request run out after ten minutes.
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
    public func publish(context: LAContext, clearing: Set<String> = []) async throws {
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
            .subtracting([keys.deviceKeyID, keys.machineID])
        try await publishSealed(for: others, clearing: clearing.intersection(others))
    }

    private func publishSealed(for openers: Set<String>, clearing: Set<String> = []) async throws {
        var batch = Agentkeyring_V2_SealedLogins()
        batch.logins = try await store.sealed().filter { openers.contains($0.openerID) }
        batch.clearedOpeners = clearing.sorted()
        guard !batch.logins.isEmpty || !batch.clearedOpeners.isEmpty else { return }
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
