// Written by AI on 2026.11.21 by model claude opus 5.5, from the relay's join
// handling (internal/relay/documents.go) and MacDevice's own.
//
// Devices and computers join this Mac at its door (keyring.proto, JoinRequest
// and "Direct: no relay"). A join is shown only if its proof checks against
// an invitation this Mac issued and has not withdrawn. Each join is one value
// with one state (docs/state-machines.md, "Joining the Mac"):
//
//   waiting → approved   Josh's Touch ID, which publishes the new members list
//   waiting → refused    Josh denied it, with his words for a computer's agent
//   waiting → expired    ten minutes after it was first asked, connected or not
//   waiting → withdrawn  the joiner cancelled, or a second joiner proved the
//                        same invitation (then both are withdrawn and neither shown)

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The invitation for a new iPhone in iCloud Keychain, where only Agent
/// Keyring's own apps on Josh's devices can read it; nothing in tests.
public struct InvitationItem: Sendable {
    let read: @MainActor @Sendable () -> Agentkeyring_V2_JoinInvite?
    let write: @MainActor @Sendable (Agentkeyring_V2_JoinInvite) -> Void

    private static var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: true,
         kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringSharedKeychainGroup") as? String ?? "",
         kSecAttrService as String: "com.joshpalmer.AgentKeyring.invitation", kSecAttrAccount as String: "relay"]
    }

    public static let iCloud = InvitationItem(read: {
        var query = itemQuery
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let bytes = found as? Data else { return nil }
        return try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes)
    }, write: { invite in
        guard let value = try? invite.serializedData() else { return }
        SecItemDelete(itemQuery as CFDictionary)
        var item = itemQuery
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        DiagnosticLog.record("invitation", status == errSecSuccess ? "left" : "not-left",
            ["door": invite.doorHost.isEmpty ? "none" : "yes", "status": "\(status)"])
    })

    public static let nowhere = InvitationItem(read: { nil }, write: { _ in })
}

@MainActor
extension MacDevice {
    /// One join this Mac has heard, by joiner: a computer's machine ID or a device's key ID.
    struct Join {
        /// Unique per waiting attempt so Touch ID for a cancelled attempt cannot approve a replacement.
        let attemptID = UUID()
        let request: Agentkeyring_V2_JoinRequest
        /// The invitation it proved.
        let secret: Data
        /// First asked: it expires ten minutes after, whether or not the joiner stays connected.
        let asked: Date
        var state: Agentkeyring_V2_JoinState
        var refusal: Agentkeyring_V2_JoinRefusal?
        /// For a computer approved while this Mac held the push key.
        var pushCredential: Agentkeyring_V2_SealedPushCredential?
    }

    /// A new device being given its copies: Josh sees how far it has got.
    public struct Filling: Equatable, Sendable {
        public let deviceKeyID: String
        public let label: String
        public var done: Int
        public let total: Int
        /// Why copying stopped, if it did.
        public var failure: String?
    }

    static let joinLasts: TimeInterval = 600

    /// The joins waiting for Josh, oldest first.
    public var joins: [Agentkeyring_V2_PendingJoin] {
        joinRecords.values.filter { $0.state == .waiting && $0.asked.addingTimeInterval(Self.joinLasts) > .now }
            .sorted { $0.asked < $1.asked }.map { join in
                var pending = Agentkeyring_V2_PendingJoin()
                pending.request = join.request
                pending.askedUnixSeconds = Int64(join.asked.timeIntervalSince1970)
                return pending
            }
    }

    public static func joinID(_ join: Agentkeyring_V2_PendingJoin) -> String { joinerID(join.request) ?? "" }

    static func joinerID(_ request: Agentkeyring_V2_JoinRequest) -> String? {
        switch request.joining {
        case let .machine(machine)?: machine.machineID
        case let .device(device)?: device.keyID
        case nil: nil
        }
    }

    // MARK: Invitations

    /// A one-time link for one computer to join, valid for ten minutes, for an
    /// agent to pass to `agent-keyring enrol --invite` over SSH.
    public func inviteMachine() throws -> String {
        try machineInvite().link
    }

    /// One invitation for one computer: its link, when it runs out, and its secret, by which its join is found.
    public struct MachineInvite: Equatable, Sendable {
        public let link: String
        public let expires: Date
        public let secret: Data
    }

    public func machineInvite() throws -> MachineInvite {
        let invite = try invitation(lasting: Self.joinLasts)
        return MachineInvite(link: "agentkeyring://join?invite=" + (try invite.serializedData()).base64URLEncoded,
            expires: Date(timeIntervalSince1970: TimeInterval(invite.expiresUnixSeconds)), secret: invite.secret)
    }

    /// A join this Mac has heard, as the Add sheets show it.
    public struct JoinSummary: Equatable, Sendable {
        public enum Joiner: Equatable, Sendable { case device(Agentkeyring_V2_DeviceKind), computer }
        public let id: String
        public let label: String
        public let joiner: Joiner
        /// Waiting past its ten minutes counts as expired.
        public let state: Agentkeyring_V2_JoinState
        public let asked: Date
        /// The invitation it proved.
        public let secret: Data
    }

    /// Every join heard since the app started, newest first.
    public var joinHistory: [JoinSummary] {
        joinRecords.compactMap { id, join -> JoinSummary? in
            let joiner: JoinSummary.Joiner
            let label: String
            switch join.request.joining {
            case let .device(device)?: joiner = .device(device.kind); label = device.label
            case let .machine(machine)?: joiner = .computer; label = machine.label
            case nil: return nil
            }
            let ranOut = join.state == .waiting && join.asked.addingTimeInterval(Self.joinLasts) <= .now
            return JoinSummary(id: id, label: label, joiner: joiner, state: ranOut ? .expired : join.state, asked: join.asked, secret: join.secret)
        }.sorted { $0.asked > $1.asked }
    }

    private func invitation(lasting seconds: TimeInterval) throws -> Agentkeyring_V2_JoinInvite {
        guard case let .open(host, _, port) = door else {
            throw RelayFailure(.unavailable, door == .noTailscale ? MessageCopy.noTailscale : MessageCopy.doorClosed("\(door)"))
        }
        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let expires = Date.now.addingTimeInterval(seconds)
        invitations[secret] = expires
        var invite = nameOnly
        invite.secret = secret
        invite.expiresUnixSeconds = Int64(expires.timeIntervalSince1970)
        invite.doorHost = host
        invite.doorPort = UInt32(port)
        invite.doorTlsPublicKey = keys.tls.publicKeySPKI
        return invite
    }

    private var nameOnly: Agentkeyring_V2_JoinInvite {
        var invite = Agentkeyring_V2_JoinInvite()
        invite.inviterKeyID = keys.deviceKeyID
        invite.inviterLabel = keys.label
        return invite
    }

    /// Keeps a full invitation in iCloud Keychain whenever the door is open:
    /// the one there is kept while it is this Mac's, names the door as it is,
    /// and has a day left. A new one replaces it after it admits a joiner or is
    /// withdrawn. With no Tailscale address the item names this Mac only.
    func leaveInvitation(replacing: Bool = false) {
        let item = environment.invitationItem
        guard case let .open(host, _, port) = door else {
            if item.read()?.inviterKeyID != keys.deviceKeyID || item.read()?.doorHost.isEmpty == false { item.write(nameOnly) }
            return
        }
        if !replacing, let current = item.read(), current.inviterKeyID == keys.deviceKeyID, current.doorHost == host,
            current.doorPort == UInt32(port), current.doorTlsPublicKey == keys.tls.publicKeySPKI, !current.secret.isEmpty,
            current.expiresUnixSeconds > Int64(Date.now.timeIntervalSince1970) + 86400 {
            invitations[current.secret] = Date(timeIntervalSince1970: TimeInterval(current.expiresUnixSeconds))
            return
        }
        if let invite = try? invitation(lasting: 7 * 86400) { item.write(invite) }
    }

    /// An invitation is used up or withdrawn: if it was the one in iCloud Keychain, a new one takes its place.
    private func retire(_ secret: Data) {
        invitations.removeValue(forKey: secret)
        if environment.invitationItem.read()?.secret == secret { leaveInvitation(replacing: true) }
    }

    // MARK: The door's join routes

    func takeJoin(_ door: DoorRequest) async -> DoorReply {
        guard let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: door.body), let id = Self.joinerID(request) else {
            return .refused(400, "The body must be a JoinRequest naming a computer or a device.")
        }
        if let refusal = keysRefusal(request, peer: door.peerSPKI) { return refusal }
        if isMember(request) { return .ok(message(status(.approved, for: request))) }
        let now = Date.now
        if let existing = joinRecords[id], existing.state == .refused, existing.request == request {
            // Preserve terminal refusal (and owner explanation) when a computer retries after missing the reply.
            var reply = status(.refused, for: request)
            if let refusal = existing.refusal { reply.refusal = refusal }
            return .ok(message(reply))
        }
        if let existing = joinRecords[id], existing.state == .waiting {
            guard existing.request == request else { return .refused(403, "Another request to join with these keys is waiting.") }
        } else {
            invitations = invitations.filter { $0.value > now }
            guard let secret = invitations.keys.first(where: { Sealing.joinProof(secret: $0, joining: request) == request.proof }) else {
                return .refused(403, "This invitation is not one this Mac issued, or it has run out. Ask for a new one on the Mac.")
            }
            if let other = joinRecords.first(where: { $0.key != id && $0.value.secret == secret && $0.value.state == .waiting })?.key {
                // The secret has leaked: neither is shown, and the invitation goes.
                DiagnosticLog.record("join", "withdrawn", ["reason": "two joiners proved one invitation"])
                joinRecords[other]?.state = .withdrawn
                joinRecords[id] = Join(request: request, secret: secret, asked: now, state: .withdrawn)
                retire(secret)
                joinSignal.fire()
                return .ok(message(status(.withdrawn, for: request)))
            }
            joinRecords[id] = Join(request: request, secret: secret, asked: now, state: .waiting)
            DiagnosticLog.record("join", "asked", ["joiner": String(id.prefix(16))])
            joinSignal.fire()
        }
        // Wait for Josh, up to the long poll's limit or the join's ten minutes.
        let attemptID = joinRecords[id]!.attemptID
        let asked = joinRecords[id]!.asked
        let lastsFor = asked.addingTimeInterval(Self.joinLasts).timeIntervalSinceNow
        let deadline = ContinuousClock.now + min(environment.joinWait, .seconds(max(0, lastsFor)))
        while joinRecords[id]?.attemptID == attemptID, joinRecords[id]?.state == .waiting, ContinuousClock.now < deadline, !Task.isCancelled {
            await joinSignal.wait(until: deadline)
        }
        if joinRecords[id]?.attemptID == attemptID, joinRecords[id]?.state == .waiting, asked.addingTimeInterval(Self.joinLasts) <= .now {
            joinRecords[id]?.state = .expired
            joinSignal.fire()
        }
        guard let join = joinRecords[id], join.attemptID == attemptID else { return .ok(message(status(.withdrawn, for: request))) }
        var status = status(join.state, for: request)
        if let refusal = join.refusal { status.refusal = refusal }
        if join.state == .approved, isMember(request), let sealed = join.pushCredential { status.pushCredential = sealed }
        return .ok(message(status))
    }

    func takeWithdrawal(_ door: DoorRequest) -> DoorReply {
        guard let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: door.body), let id = Self.joinerID(request) else {
            return .refused(400, "The body must be the JoinRequest being withdrawn.")
        }
        if let refusal = keysRefusal(request, peer: door.peerSPKI) { return refusal }
        if joinRecords[id]?.state == .waiting, joinRecords[id]?.request == request {
            joinRecords[id]?.state = .withdrawn
            DiagnosticLog.record("join", "withdrawn", ["reason": "the joiner cancelled"])
            joinSignal.fire()
        }
        return .ok()
    }

    /// A computer joins with its own TLS key, the one its connection shows; a
    /// device with its own, or an Apple Watch through its iPhone, already added.
    private func keysRefusal(_ request: Agentkeyring_V2_JoinRequest, peer: Data?) -> DoorReply? {
        switch request.joining {
        case let .machine(machine)?:
            guard let peer, machine.tlsPublicKey == peer, machine.machineID == Sealing.keyID(machine.tlsPublicKey),
                (try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)) != nil else {
                return .refused(403, "A computer joins with its own TLS key, the one its connection shows, and a receiving key.")
            }
        case let .device(device)?:
            let own = !device.tlsPublicKey.isEmpty && device.tlsPublicKey == peer
            let throughPhone = device.kind == .watch && { if case let .device(phone)? = caller(peer) { phone.kind == .iphone } else { false } }()
            guard own || throughPhone, device.keyID == Sealing.keyID(device.signingPublicKey),
                (try? P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)) != nil else {
                return .refused(403, "A device joins with its own keys over its own connection, or an Apple Watch through its iPhone.")
            }
        case nil:
            return .refused(400, "Join as a computer or a device.")
        }
        return nil
    }

    /// Already in the members list with exactly these keys: a long poll that dropped after Touch ID still hears it was approved.
    private func isMember(_ request: Agentkeyring_V2_JoinRequest) -> Bool {
        switch request.joining {
        case let .machine(machine)?:
            members?.machines.contains { $0.machineID == machine.machineID && $0.receivingPublicKey == machine.receivingPublicKey } == true
        case let .device(device)?:
            members?.devices.contains { $0.keyID == device.keyID && $0.openingPublicKey == device.openingPublicKey } == true
        case nil: false
        }
    }

    private func status(_ state: Agentkeyring_V2_JoinState, for request: Agentkeyring_V2_JoinRequest) -> Agentkeyring_V2_JoinStatus {
        var status = Agentkeyring_V2_JoinStatus()
        status.state = state
        if state == .approved, isMember(request), let bytes = saved.members, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) {
            status.members = signed
            if case let .machine(machine)? = request.joining, let sealed = sealedPushCredential(for: machine) { status.pushCredential = sealed }
        }
        return status
    }

    private func sealedPushCredential(for machine: Agentkeyring_V2_Machine) -> Agentkeyring_V2_SealedPushCredential? {
        guard let credential = push?.credential, let key = try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey) else { return nil }
        return try? Sealing.sealPushCredential(credential, to: key, machineID: machine.machineID)
    }

    // MARK: Josh's answer

    /// The sentence for approving a join, after "Agent Keyring is trying to".
    public func joinReason(_ id: String) -> String {
        switch joinRecords[id]?.request.joining {
        case let .machine(machine)?: MessageCopy.add(machine.label)
        case let .device(device)?: MessageCopy.add(device.label)
        case nil: MessageCopy.addADevice
        }
    }

    /// Lets a computer or device join, after Josh's Touch ID. It is in the
    /// members list at once, so its long poll hears in a moment. The first
    /// join also makes the first members list and catalogue. A new device then
    /// gets a copy of every password, opened here with the same approval and
    /// sealed again for it off the main thread, in batches it can count. A
    /// computer gets Apple's push credential and copies of every existing
    /// Automatic password right away.
    public func approveJoin(_ id: String, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        guard let join = joinRecords[id], join.state == .waiting else { throw RelayFailure(.notFound, MessageCopy.nothingJoining) }
        guard join.asked.addingTimeInterval(Self.joinLasts) > .now else {
            joinRecords[id]?.state = .expired
            joinSignal.fire()
            throw RelayFailure(.notFound, MessageCopy.joinRanOut)
        }
        let attemptID = join.attemptID
        try await confirm(context, reason: joinReason(id))
        // Re-check after Touch ID against the exact waiting attempt so a cancelled-and-replaced
        // join with identical keys/invitation can never inherit an earlier Touch ID confirmation.
        guard let liveJoin = joinRecords[id], liveJoin.attemptID == attemptID,
              liveJoin.state == .waiting, liveJoin.request == join.request else {
            throw RelayFailure(.notFound, MessageCopy.nothingJoining)
        }
        guard liveJoin.asked.addingTimeInterval(Self.joinLasts) > .now else {
            joinRecords[id]?.state = .expired
            joinSignal.fire()
            throw RelayFailure(.notFound, MessageCopy.joinRanOut)
        }
        onAuthenticated()
        var next = members ?? {
            var first = Agentkeyring_V2_Members()
            var thisMac = keys.machine
            thisMac.automaticAllowed = true
            first.devices = [keys.device]
            first.machines = [thisMac]
            return first
        }()
        for index in next.machines.indices { next.machines[index].automaticAllowed = true }
        var newDevice: Agentkeyring_V2_Device?
        var newMachine: Agentkeyring_V2_Machine?
        switch join.request.joining {
        case var .machine(machine)?:
            machine.automaticAllowed = true
            next.machines.removeAll { $0.machineID == machine.machineID }
            next.machines.append(machine)
            newMachine = machine
        case let .device(device)?:
            next.devices.removeAll { $0.keyID == device.keyID }
            next.devices.append(device)
            newDevice = device
        case nil:
            return
        }
        try await publishMembers(next, context: context)
        // A new approving device needs a signed catalogue matching this Mac's current copies;
        // a new computer takes its Automatic passwords from the last approved catalogue so
        // unrelated pending Passwords imports wait for "Send Changes".
        if catalogue == nil || newDevice != nil {
            try await publish(context: context)
        }
        if let newMachine, let liveCatalogue = catalogue, let liveMembers = members {
            let listedAutomatic = Dictionary(
                liveCatalogue.logins.filter { $0.rule == .automatic }.map { ($0.loginID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            if !listedAutomatic.isEmpty {
                var savedCount = 0
                do {
                    let allSealed = try await store.sealed()
                    let mine = allSealed.filter {
                        $0.openerID == keys.deviceKeyID && listedAutomatic[$0.loginID]?.version == $0.version
                    }
                    let key = try P256.KeyAgreement.PublicKey(x963Representation: newMachine.receivingPublicKey)
                    let resealer = try keys.resealer(context: context, members: liveMembers)
                    let machineID = newMachine.machineID
                    let batchResults = await Task.detached { () -> ([Agentkeyring_V2_SealedLogin], Int) in
                        var sealed: [Agentkeyring_V2_SealedLogin] = []
                        sealed.reserveCapacity(mine.count)
                        var failures = 0
                        for copy in mine {
                            if let resealed = try? resealer.reseal(copy, to: key, openerID: machineID) {
                                sealed.append(resealed)
                            } else {
                                failures += 1
                            }
                        }
                        return (sealed, failures)
                    }.value
                    let sealed = batchResults.0
                    if !sealed.isEmpty, members?.machines.contains(where: { $0.machineID == machineID }) == true {
                        try await store.mergeSealed(replacingOpener: machineID, with: sealed)
                        savedCount = sealed.count
                        listsChanged(copies: true)
                    }
                    if batchResults.1 > 0 || savedCount != listedAutomatic.count {
                        DiagnosticLog.record("devices", "automatic-fill-incomplete", [
                            "computer": newMachine.label,
                            "saved": "\(savedCount)",
                            "expected": "\(listedAutomatic.count)",
                        ])
                    }
                } catch {
                    DiagnosticLog.record("devices", "automatic-fill-failed", ["computer": newMachine.label, "reason": "\(error)"])
                }
                // Always refresh after the fill completes: publishMembers ran before the fill, so a clean fill
                // must clear automaticCopiesMissing and an incomplete/failed fill must keep it set.
                await onAutomaticCopiesChanged?()
            }
        }
        joinRecords[id]?.state = .approved
        if case let .machine(machine)? = join.request.joining {
            joinRecords[id]?.pushCredential = sealedPushCredential(for: machine)
            if push == nil { DiagnosticLog.record("join", "no-push-key", ["computer": machine.label]) }
        }
        retire(join.secret)
        joinSignal.fire()
        DiagnosticLog.record("join", "approved", ["joiner": String(id.prefix(16))])
        guard let newDevice else { return }
        // Its copies: every password not Blocked, matching the just-published catalogue version.
        let listed = Dictionary((catalogue?.logins ?? []).filter { $0.rule != .blocked }.map { ($0.loginID, $0.version) },
            uniquingKeysWith: { first, _ in first })
        let mine = try await store.sealed().filter { $0.openerID == keys.deviceKeyID && listed[$0.loginID] == $0.version }
        filling = Filling(deviceKeyID: newDevice.keyID, label: newDevice.label, done: 0, total: mine.count)
        let fillingID = newDevice.keyID
        Task {
            do { try await fill(newDevice, copies: mine, context: context) } catch {
                DiagnosticLog.record("devices", "fill-failed", ["device": newDevice.label, "reason": "\(error)"])
                if filling?.deviceKeyID == fillingID {
                    filling?.failure = (error as? LocalizedError)?.errorDescription ?? MessageCopy.somethingWentWrong
                }
                try? await Task.sleep(for: .seconds(30)) // Long enough to read in the panel.
            }
            if filling?.deviceKeyID == fillingID { filling = nil }
        }
    }

    func fill(_ device: Agentkeyring_V2_Device, copies mine: [Agentkeyring_V2_SealedLogin], context: LAContext) async throws {
        guard let members else { return }
        let key = try P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)
        let resealer = try keys.resealer(context: context, members: members)
        DiagnosticLog.record("devices", "filling", ["device": device.label, "passwords": "\(mine.count)"])
        let started = ContinuousClock.now
        for start in stride(from: 0, to: mine.count, by: 50) {
            let batch = Array(mine[start..<min(start + 50, mine.count)])
            let sealed = try await Task.detached { try batch.map { try resealer.reseal($0, to: key, openerID: device.keyID) } }.value
            try await store.mergeSealed(replacingOpener: device.keyID, with: sealed)
            if filling?.deviceKeyID == device.keyID { filling?.done = start + batch.count }
            listsChanged(copies: true)
        }
        DiagnosticLog.record("devices", "filled", ["device": device.label, "passwords": "\(mine.count)",
            "seconds": "\((ContinuousClock.now - started).components.seconds)"])
    }

    /// Josh denied a computer or device: its waiting request hears at once,
    /// and a computer's agent gets his words. The invitation is withdrawn.
    /// True if the words reach the agent.
    public func refuseJoin(_ id: String, reply: String) -> Bool {
        guard let join = joinRecords[id], join.state == .waiting else { return false }
        retire(join.secret)
        joinRecords[id]?.state = .refused
        defer { joinSignal.fire() }
        guard case let .machine(machine)? = join.request.joining, !join.request.refusalKeySha256.isEmpty else { return false }
        var refusal = Agentkeyring_V2_JoinRefusal()
        refusal.joinerID = machine.machineID
        refusal.key = Sealing.refusalKey(secret: join.secret, machineID: machine.machineID)
        refusal.reply = reply
        refusal.replyProof = Sealing.refusalReplyProof(secret: join.secret, machineID: machine.machineID, reply: reply)
        joinRecords[id]?.refusal = refusal
        return true
    }
}
