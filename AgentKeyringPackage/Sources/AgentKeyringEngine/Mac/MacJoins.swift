// Written by AI on 2026.11.21 by model claude opus 5.5, from the relay's join
// handling (since deleted) and MacSyncCoordinator's own; joining with a code through
// boxes on 2026.11.23; the door's joins cut on 2026.11.24.
//
// Computers join this Mac with a code, through boxes at the relay
// (keyring.proto, "Joining with a code"); an iPhone or another Mac through
// iCloud, proving the invitation this Mac left in iCloud Keychain
// (MacCloud.swift, takeCloudJoin). A join is shown only if its proof checks
// against an invitation or code this Mac issued and has not withdrawn. Each
// join is one value with one state (docs/state-machines.md, "Joining the Mac"):
//
//   waiting → approved   Josh's Touch ID, which publishes the new members list
//   waiting → refused    Josh denied it, with his words for a computer's agent
//   waiting → expired    ten minutes after it was first asked
//   waiting → withdrawn  the joiner cancelled

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A new device being given its copies: Josh sees how far it has got.
public struct EnrollingDeviceCopyProgress: Equatable, Sendable {
    public let deviceKeyID: String
    public let label: String
    public var done: Int
    public let total: Int
    /// Why copying stopped, if it did.
    public var failure: String?
}

@MainActor
extension MacSyncCoordinator {
    /// One join this Mac has heard, by joiner: a computer's machine ID or a device's key ID.
    struct HeardJoinRequest {
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

    static let joinLasts: TimeInterval = 600

    /// The joins waiting for Josh, oldest first.
    public var joins: [Agentkeyring_V2_PendingJoin] {
        joinRecords.values.filter { join in
            guard join.state == .waiting, join.asked.addingTimeInterval(Self.joinLasts) > .now else { return false }
            if case let .device(device)? = join.request.joining, device.kind == .mac {
                return cloudMachineJoins[device.keyID] != nil
            }
            return true
        }
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

    /// A one-time code for one computer to join, valid for ten minutes, for an
    /// agent to pass to `agent-keyring enrol --code` over SSH.
    public func inviteMachine() throws -> String {
        try machineInvite().code.enrolArgument
    }

    /// One join code for one computer: the code, when it runs out, and the secret its join proves, by which
    /// its join is found. The join comes through boxes at the relay.
    public struct MachineInvite: Equatable, Sendable {
        public let code: ComputerJoinCode
        public let expires: Date
        public let secret: Data
    }

    public func machineInvite() throws -> MachineInvite {
        let relay = environment.relay
        let code = ComputerJoinCode.make(relay: relay.url)
        let keys = code.keys
        let expires = Date.now.addingTimeInterval(Self.joinLasts)
        invitations[keys.proof] = expires
        joinBoxTasks[keys.proof]?.cancel()
        joinBoxTasks[keys.proof] = Task { [weak self] in
            defer { self?.joinBoxTasks.removeValue(forKey: keys.proof) }
            await self?.takeJoinBox(keys, at: relay, until: expires)
        }
        return MachineInvite(code: code, expires: expires, secret: keys.proof)
    }

    // MARK: Joining with a code

    /// The sheet made a new code or closed: a code no computer has used yet stops working.
    public func withdrawCode(_ invite: MachineInvite) {
        guard !joinRecords.values.contains(where: { $0.secret == invite.secret }) else { return }
        invitations.removeValue(forKey: invite.secret)
        joinBoxTasks.removeValue(forKey: invite.secret)?.cancel()
    }

    /// A computer joining with a code: this Mac picks up the code's request box every two seconds until the
    /// code runs out, is used or withdrawn, shows the join, and once Josh decides, or ten minutes pass, puts
    /// the JoinStatus in the code's response box, with the computer's lists, its update mailbox and its
    /// challenge. A join naming a computer already in the members list with other keys is refused: nobody can
    /// take an added computer's place. The same keys again (a computer that missed its approval) is shown and
    /// approved like any join.
    func takeJoinBox(_ keys: ComputerJoinCodeKeys, at relay: RelayBoxClient, until expires: Date) async {
        guard let request = await ComputerJoinCoordinator.takeComputerJoinRequest(keys, at: relay, until: expires, stillWanted: { [weak self] in
            self?.invitations[keys.proof] != nil
        }), let machine = ComputerJoinCoordinator.joiningComputer(request) else {
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "box-refused", ["reason": "no computer's join proving this code"])
            return
        }
        retire(keys.proof)
        let id = machine.machineID
        var reply: Agentkeyring_V2_JoinStatus
        let otherKeys = members?.machines.contains { $0.machineID == id && $0.receivingPublicKey != machine.receivingPublicKey } == true
        if otherKeys || joinRecords[id]?.state == .waiting {
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "box-refused", ["reason": "a computer already added or waiting"])
            reply = ComputerJoinCoordinator.refusedJoinStatus(request, keys, reply: MessageCopy.alreadyAdded)
        } else {
            joinRecords[id] = HeardJoinRequest(request: request, secret: keys.proof, asked: .now, state: .waiting)
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "asked", ["joiner": String(id.prefix(16)), "route": "box"])
            joinSignal.fire()
            let attemptID = joinRecords[id]!.attemptID
            let deadline = ContinuousClock.now + .seconds(Self.joinLasts)
            while joinRecords[id]?.attemptID == attemptID, joinRecords[id]?.state == .waiting, ContinuousClock.now < deadline, !Task.isCancelled {
                await joinSignal.wait(until: deadline)
            }
            if joinRecords[id]?.attemptID == attemptID, joinRecords[id]?.state == .waiting {
                joinRecords[id]?.state = .expired
                joinSignal.fire()
            }
            guard let join = joinRecords[id], join.attemptID == attemptID else { return }
            reply = status(join.state, for: request)
            if let refusal = join.refusal { reply.refusal = refusal }
            if join.state == .approved, isMember(request) {
                if let sealed = join.pushCredential { reply.pushCredential = sealed }
                do { reply.mailbox = UpdateMailboxWriter.mailboxGivenToComputer(try makeMailbox(for: machine.machineID, at: relay)) } catch {
                    // Unanswered, the computer asks again and is approved again once the mailbox is saved.
                    KeyringDiagnosticLog.mac.noteDeviceEvent("join", "box-not-answered", ["joiner": String(id.prefix(16)), "reason": "\(error)"])
                    return
                }
                reply.bundle = await bundle(for: machine, holding: 0)
            }
        }
        do {
            try await ComputerJoinCoordinator.sendJoinStatus(reply, to: request, keys, at: relay)
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "box-answered", ["joiner": String(id.prefix(16)), "state": "\(reply.state)"])
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "box-not-answered", ["joiner": String(id.prefix(16)), "reason": "\(error)"])
        }
    }

    /// A new mailbox for a computer this Mac is adding (AgentKeyringEngine/Cloud/ComputerMailboxPublisher.swift): kept
    /// here, shared in iCloud, and written with every change to the lists.
    private func makeMailbox(for machineID: String, at relay: RelayBoxClient) throws -> Agentkeyring_V2_UpdateMailbox {
        let mailbox = cloudSync.mailboxes.heldMailboxes[machineID] ?? UpdateMailboxWriter.makeUpdateMailbox(for: machineID, at: relay)
        try cloudSync.mailboxes.keepComputerMailbox(mailbox)
        return mailbox
    }

    /// A join this Mac has heard, as the Add sheets show it.
    public struct JoinSummary: Equatable, Sendable {
        public enum JoinRequesterKind: Equatable, Sendable { case device(Agentkeyring_V2_DeviceKind), computer }
        public let id: String
        public let label: String
        public let joiner: JoinRequesterKind
        /// Waiting past its ten minutes counts as expired.
        public let state: Agentkeyring_V2_JoinState
        public let asked: Date
        /// The invitation it proved.
        public let secret: Data
        public let replies: Bool
        public let refusalReply: String?

        public init(
            id: String,
            label: String,
            joiner: JoinRequesterKind,
            state: Agentkeyring_V2_JoinState,
            asked: Date,
            secret: Data,
            replies: Bool = false,
            refusalReply: String? = nil
        ) {
            self.id = id
            self.label = label
            self.joiner = joiner
            self.state = state
            self.asked = asked
            self.secret = secret
            self.replies = replies
            self.refusalReply = refusalReply
        }
    }

    /// Every join heard since the app started, newest first.
    public var joinHistory: [JoinSummary] {
        joinRecords.compactMap { id, join -> JoinSummary? in
            let joiner: JoinSummary.JoinRequesterKind
            let label: String
            switch join.request.joining {
            case let .device(device)?:
                if device.kind == .mac, join.state == .waiting, cloudMachineJoins[device.keyID] == nil {
                    return nil
                }
                joiner = .device(device.kind)
                label = device.label
            case let .machine(machine)?: joiner = .computer; label = machine.label
            case nil: return nil
            }
            let ranOut = join.state == .waiting && join.asked.addingTimeInterval(Self.joinLasts) <= .now
            let refusalReply: String? = join.refusal.flatMap { $0.reply.isEmpty ? nil : $0.reply }
            return JoinSummary(
                id: id,
                label: label,
                joiner: joiner,
                state: ranOut ? .expired : join.state,
                asked: join.asked,
                secret: join.secret,
                replies: !join.request.refusalKeySha256.isEmpty,
                refusalReply: refusalReply
            )
        }.sorted { $0.asked > $1.asked }
    }

    /// A new invitation, for an iPhone or Mac that joins through iCloud (MacCloud.swift), proving its secret.
    private func invitation(lasting seconds: TimeInterval) -> Agentkeyring_V2_JoinInvite {
        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let expires = Date.now.addingTimeInterval(seconds)
        invitations[secret] = expires
        var invite = nameOnly
        invite.secret = secret
        invite.expiresUnixSeconds = Int64(expires.timeIntervalSince1970)
        return invite
    }

    private var nameOnly: Agentkeyring_V2_JoinInvite {
        var invite = Agentkeyring_V2_JoinInvite()
        invite.inviterKeyID = keys.deviceKeyID
        invite.inviterLabel = keys.label
        return invite
    }

    /// Keeps an invitation in iCloud Keychain: the one there is kept while it is this Mac's, names no door,
    /// and has a day left. A new one replaces it after it admits a joiner or is withdrawn, and one an earlier
    /// version left naming this Mac's door. The item is shared by all his devices: another Mac's invitation
    /// is replaced only when Josh adds an iPhone here (`claiming`).
    func leaveInvitation(replacing: Bool = false, claiming: Bool = false) {
        guard claiming || mayLeaveInvitation || members != nil else { return }
        if claiming { mayLeaveInvitation = true }
        let item = environment.invitationStore
        if !claiming, let current = item.read(), !current.inviterKeyID.isEmpty, current.inviterKeyID != keys.deviceKeyID { return }
        if !replacing, let current = item.read(), current.inviterKeyID == keys.deviceKeyID, current.unknownFields.data.isEmpty,
            !current.secret.isEmpty, current.expiresUnixSeconds > Int64(Date.now.timeIntervalSince1970) + 86400 {
            invitations[current.secret] = Date(timeIntervalSince1970: TimeInterval(current.expiresUnixSeconds))
            return
        }
        let left = item.write(invitation(lasting: 7 * 86400))
        KeyringDiagnosticLog.mac.noteDeviceEvent("invitation", left ? "left" : "not-left")
    }

    /// "Add your iPhone" opened on this Mac: the invitation in iCloud Keychain becomes this Mac's, even if another Mac left one.
    public func leaveInvitationForIPhone() {
        leaveInvitation(claiming: true)
        cloudSync.pollQuicklyUntil = .now.addingTimeInterval(Self.joinLasts)
        cloudChanged()
    }

    /// An invitation is used up or withdrawn: if it was the one in iCloud Keychain, a new one takes its place.
    private func retire(_ secret: Data) {
        invitations.removeValue(forKey: secret)
        if environment.invitationStore.read()?.secret == secret { leaveInvitation(replacing: true) }
    }

    /// Already in the members list with exactly these keys: a join that missed its answer still hears it was approved.
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
        return try? CredentialSealing.sealPushCredential(credential, to: key, machineID: machine.machineID)
    }

    // MARK: Josh's answer

    /// The sentence for approving a join, after "Agent Keyring is trying to".
    func joinReason(_ id: String) -> String {
        switch joinRecords[id]?.request.joining {
        case let .machine(machine)?: MessageCopy.add(machine.label)
        case let .device(device)?: MessageCopy.add(device.label)
        case nil: MessageCopy.addADevice
        }
    }

    /// Lets a computer or device join, after Josh's Touch ID. It is in the
    /// members list at once, so its join hears in a moment. The first
    /// join also makes the first members list and catalogue. A new device then
    /// gets a copy of every password, opened here with the same approval and
    /// sealed again for it off the main thread, in batches it can count. A
    /// computer gets Apple's push credential and copies of every existing
    /// Automatic password right away.
    public func approveJoin(_ id: String, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        guard let join = joinRecords[id], join.state == .waiting else { throw AgentRPCError(.notFound, MessageCopy.nothingJoining) }
        guard join.asked.addingTimeInterval(Self.joinLasts) > .now else {
            joinRecords[id]?.state = .expired
            joinSignal.fire()
            throw AgentRPCError(.notFound, MessageCopy.joinRanOut)
        }
        let attemptID = join.attemptID
        try await confirm(context, reason: joinReason(id))
        // Re-check after Touch ID against the exact waiting attempt so a cancelled-and-replaced
        // join with identical keys/invitation can never inherit an earlier Touch ID confirmation.
        guard let liveJoin = joinRecords[id], liveJoin.attemptID == attemptID,
              liveJoin.state == .waiting, liveJoin.request == join.request else {
            throw AgentRPCError(.notFound, MessageCopy.nothingJoining)
        }
        guard liveJoin.asked.addingTimeInterval(Self.joinLasts) > .now else {
            joinRecords[id]?.state = .expired
            joinSignal.fire()
            throw AgentRPCError(.notFound, MessageCopy.joinRanOut)
        }
        onAuthenticated()
        let (newDevice, newMachine) = try await addJoinerToMembers(join, context: context)
        if newDevice == nil, newMachine == nil { return }
        // A new approving device needs a signed catalogue matching this Mac's current copies;
        // a new computer takes its Automatic passwords from the last approved catalogue so
        // unrelated pending Passwords imports wait for "Send Changes".
        if catalogue == nil || newDevice != nil {
            try await publish(context: context)
        }
        if let newMachine, let liveCatalogue = catalogue, let liveMembers = members {
            await sealAutomaticCopies(for: newMachine, catalogue: liveCatalogue, members: liveMembers, context: context)
        }
        // Load sealed copies BEFORE marking the join approved so state = .approved and filling = Filling(...)
        // happen synchronously in one actor turn and ApprovalPresenter never closes mid-fill.
        var mine: [Agentkeyring_V2_SealedLogin] = []
        var sealLoadError: Error?
        if newDevice != nil {
            let listed = Dictionary((catalogue?.logins ?? []).filter(\.holdsSecret).map { ($0.loginID, $0.version) },
                uniquingKeysWith: { first, _ in first })
            do {
                mine = try await store.sealed().filter { $0.openerID == keys.deviceKeyID && listed[$0.loginID] == $0.version }
            } catch {
                sealLoadError = error
            }
        }
        joinRecords[id]?.state = .approved
        if case let .machine(machine)? = join.request.joining {
            joinRecords[id]?.pushCredential = sealedPushCredential(for: machine)
            if push == nil { KeyringDiagnosticLog.mac.noteDeviceEvent("join", "no-push-key", ["computer": machine.label]) }
        }
        retire(join.secret)
        joinSignal.fire()
        KeyringDiagnosticLog.mac.noteDeviceEvent("join", "approved", ["joiner": String(id.prefix(16))])
        guard let newDevice else { return }
        startFilling(newDevice, copies: mine, sealLoadError: sealLoadError, context: context)
    }

    /// Adds the approved joiner to Members and publishes them: a new Mac comes with the computer its agents run on.
    private func addJoinerToMembers(_ join: HeardJoinRequest, context: LAContext) async throws
        -> (Agentkeyring_V2_Device?, Agentkeyring_V2_Machine?) {
        try await withSerializedMembers {
            var next = self.members ?? {
                var first = Agentkeyring_V2_Members()
                first.devices = [self.keys.device]
                first.machines = [self.keys.machine]
                return first
            }()
            var addedDevice: Agentkeyring_V2_Device?
            var addedMachine: Agentkeyring_V2_Machine?
            var poppedMachineJoinKey: String?
            switch join.request.joining {
            case let .machine(machine)?:
                next.machines.removeAll { $0.machineID == machine.machineID }
                next.machines.append(machine)
                addedMachine = machine
            case let .device(device)?:
                next.devices.removeAll { $0.keyID == device.keyID }
                next.devices.append(device)
                addedDevice = device
                // A new Mac is also the computer its own agents run on: one Touch ID adds both.
                // Its computer half proved the same invitation and must carry the device's own TLS key.
                if device.kind == .mac {
                    guard let machine = self.cloudMachineJoins[device.keyID],
                          !machine.tlsPublicKey.isEmpty, machine.tlsPublicKey == device.tlsPublicKey else {
                        throw AgentRPCError(.invalidArgument, "The joining Mac did not include a matching computer key.")
                    }
                    poppedMachineJoinKey = device.keyID
                    next.machines.removeAll { $0.machineID == machine.machineID }
                    next.machines.append(machine)
                    addedMachine = machine
                }
            case nil:
                return (nil, nil)
            }
            try await self.publishMembersUnlocked(next, context: context)
            if let poppedMachineJoinKey {
                self.cloudMachineJoins.removeValue(forKey: poppedMachineJoinKey)
            }
            return (addedDevice, addedMachine)
        }
    }

    /// A new computer's copies of every Automatic password in the last approved catalogue, sealed to it off the
    /// main thread with the join's Touch ID.
    private func sealAutomaticCopies(for newMachine: Agentkeyring_V2_Machine, catalogue liveCatalogue: Agentkeyring_V2_Catalogue,
                                     members liveMembers: Agentkeyring_V2_Members, context: LAContext) async {
        let listedAutomatic = Dictionary(
            liveCatalogue.logins.filter { $0.rule == .automatic && $0.holdsSecret }.map { ($0.loginID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !listedAutomatic.isEmpty else { return }
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
                KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "automatic-fill-incomplete", [
                    "computer": newMachine.label,
                    "saved": "\(savedCount)",
                    "expected": "\(listedAutomatic.count)",
                ])
            }
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "automatic-fill-failed", ["computer": newMachine.label, "reason": "\(error)"])
        }
        // Always refresh after the fill completes: publishMembers ran before the fill, so a clean fill
        // must clear automaticCopiesMissing and an incomplete/failed fill must keep it set.
        await onAutomaticCopiesChanged?()
    }

    /// Seals every password again for a new approving device, in the background, counting batches in `filling`.
    private func startFilling(_ newDevice: Agentkeyring_V2_Device, copies: [Agentkeyring_V2_SealedLogin],
                              sealLoadError: Error?, context: LAContext) {
        filling = EnrollingDeviceCopyProgress(deviceKeyID: newDevice.keyID, label: newDevice.label, done: 0, total: copies.count)
        let fillingID = newDevice.keyID
        fillTask?.cancel()
        fillTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.filling?.deviceKeyID == fillingID { self.filling = nil }
            }
            do {
                if let sealLoadError { throw sealLoadError }
                try await self.fill(newDevice, copies: copies, context: context)
            } catch is CancellationError {
                return
            } catch {
                KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "fill-failed", ["device": newDevice.label, "reason": "\(error)"])
                if self.filling?.deviceKeyID == fillingID {
                    self.filling?.failure = (error as? LocalizedError)?.errorDescription ?? MessageCopy.somethingWentWrong
                }
                try? await Task.sleep(for: .seconds(30)) // Long enough to read in the panel.
            }
        }
    }

    func fill(_ device: Agentkeyring_V2_Device, copies mine: [Agentkeyring_V2_SealedLogin], context: LAContext) async throws {
        guard let members else { return }
        let key = try P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)
        let resealer = try keys.resealer(context: context, members: members)
        KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "filling", ["device": device.label, "passwords": "\(mine.count)"])
        let started = ContinuousClock.now
        for start in stride(from: 0, to: mine.count, by: 50) {
            let batch = Array(mine[start..<min(start + 50, mine.count)])
            let sealed = try await Task.detached { try batch.map { try resealer.reseal($0, to: key, openerID: device.keyID) } }.value
            try await store.mergeSealed(replacingOpener: device.keyID, with: sealed)
            if filling?.deviceKeyID == device.keyID { filling?.done = start + batch.count }
            listsChanged(copies: true)
        }
        KeyringDiagnosticLog.mac.noteDeviceEvent("devices", "filled", ["device": device.label, "passwords": "\(mine.count)",
            "seconds": "\((ContinuousClock.now - started).components.seconds)"])
    }

    /// Josh denied a computer or device: its waiting join hears at once,
    /// and a computer's agent gets his words. The invitation is withdrawn.
    /// True if the words reach the agent.
    public func refuseJoin(_ id: String, reply: String) -> Bool {
        guard let join = joinRecords[id], join.state == .waiting else { return false }
        retire(join.secret)
        joinRecords[id]?.state = .refused
        defer { joinSignal.fire() }
        // An iPhone that asked through iCloud reads its request gone as not added.
        if let cloud = cloudSync.cloud, saved.cloudCheckpoint.knownNames.contains(CloudRecordKind.join(id)) { Task { try? await cloud.deleteCloudRecords([CloudRecordKind.join(id)]) } }
        guard case let .machine(machine)? = join.request.joining, !join.request.refusalKeySha256.isEmpty else { return false }
        var refusal = Agentkeyring_V2_JoinRefusal()
        refusal.joinerID = machine.machineID
        refusal.key = CredentialSealing.refusalKey(secret: join.secret, machineID: machine.machineID)
        refusal.reply = reply
        refusal.replyProof = CredentialSealing.refusalReplyProof(secret: join.secret, machineID: machine.machineID, reply: reply)
        joinRecords[id]?.refusal = refusal
        return true
    }
}
#endif
