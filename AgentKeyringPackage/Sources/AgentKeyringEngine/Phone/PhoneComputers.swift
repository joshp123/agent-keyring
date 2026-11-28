// Written by AI on 2026.11.23 by model claude opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Adding another computer with a one-time code, and the lists a computer is given.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
#if os(iOS)
import AuthenticationServices
#endif
import CryptoKit
import Foundation
import LocalAuthentication
import UserNotifications

@MainActor
extension PhoneKeyringEngine {
    // MARK: Adding another computer

    public func handleAddComputerTap(_ tap: PhoneAddComputerTap) async {
        switch tap {
        case .open:
            switch addComputerFlow {
            case .invite?, .asked?, .adding?, .deliveryFailed?: break
            default:
                if let pending = state.pendingComputerDelivery, pending.expiresAt > Date() {
                    addComputerFlow = .deliveryFailed(name: pending.machineLabel, reason: PhoneCopy.addComputerDeliveryFailed)
                } else {
                    clearPendingComputerDelivery()
                    startComputerCode()
                }
            }
        case .newCode:
            clearPendingComputerDelivery()
            startComputerCode()
        case .close:
            addingComputer?.cancel(); addingComputer = nil
            if case .adding? = addComputerFlow { return }
            if let pending = state.pendingComputerDelivery, pending.expiresAt <= Date() {
                clearPendingComputerDelivery()
            }
            computerJoin = nil
            addComputerFlow = nil
        case .approve: await approveComputer()
        case .deny: await refuseComputer()
        case .retryDelivery: await retryComputerDelivery()
        }
    }

    /// A new one-time code: the computer's join is picked up from its box, and shown for Face ID.
    private func startComputerCode() {
        addingComputer?.cancel()
        computerJoin = nil
        let relay = RelayBoxClient.configured
        let code = ComputerJoinCode.make(relay: relay.url)
        let codeKeys = code.keys
        let until = Date().addingTimeInterval(600)
        addComputerFlow = .invite(code: code.code, command: DeviceSheetCopy.enrolCommand(code.enrolArgument), until: until)
        addingComputer = Task { [weak self] in
            let request = await ComputerJoinCoordinator.takeComputerJoinRequest(codeKeys, at: relay, until: until) { !Task.isCancelled }
            guard let self, !Task.isCancelled else { return }
            guard let request, let machine = ComputerJoinCoordinator.joiningComputer(request) else { self.addComputerFlow = .expired; return }
            if self.members?.machines.contains(where: { $0.machineID == machine.machineID && $0.receivingPublicKey != machine.receivingPublicKey }) == true {
                try? await ComputerJoinCoordinator.sendJoinStatus(ComputerJoinCoordinator.refusedJoinStatus(request, codeKeys, reply: MessageCopy.alreadyAdded), to: request, codeKeys, at: relay)
                self.addComputerFlow = .notAdded(name: machine.label)
                return
            }
            self.computerJoin = (request, code.secret, codeKeys, relay, until)
            self.addComputerFlow = .asked(name: machine.label)
        }
    }

    /// A copy of every Automatic password this iPhone holds, sealed to the computer being added.
    private func automaticCopies(for machine: Agentkeyring_V2_Machine, context: LAContext) throws -> [SealedLogin] {
        guard let catalogue, let key = try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey) else { return [] }
        let automatic = Set(catalogue.logins.filter { $0.rule == .automatic && $0.holdsSecret }.map(\.loginID))
        var forComputer: [SealedLogin] = []
        for copy in ownCopies.values where automatic.contains(copy.loginID) {
            forComputer.append(try CredentialSealing.sealLogin(keys.openSealedLogin(copy, context: context), version: copy.version, to: key,
                                                openerID: machine.machineID, signer: sealSigner))
        }
        return forComputer
    }

    /// The approval put in the join's response box: the signed list, the computer's mailbox and its starting bundle.
    private func approvedJoinStatus(
        for machine: Agentkeyring_V2_Machine, members signed: SignedDocument, revision: UInt64,
        mailbox: Agentkeyring_V2_UpdateMailbox, copies forComputer: [SealedLogin]
    ) throws -> Agentkeyring_V2_JoinStatus {
        var status = Agentkeyring_V2_JoinStatus()
        status.state = .approved
        status.members = signed
        status.mailbox = UpdateMailboxWriter.mailboxGivenToComputer(mailbox)
        status.bundle = lists(for: machine.machineID, copies: .computerOnly)
        status.bundle.members = signed
        status.bundle.membersSince += [signed]
        status.bundle.copies += forComputer
        if let replyKeyID = try? CredentialSealing.keyID(keys.replyPublicKey()), let catalogue {
            status.bundle.freshness = try UpdateMailboxWriter.signFreshness(for: machine.machineID, members: revision, catalogue: catalogue.revision,
                                                              signerKeyID: replyKeyID, sign: keys.signReply)
        }
        return status
    }

    func clearPendingComputerDelivery() {
        guard state.pendingComputerDelivery != nil else { return }
        var next = state
        next.pendingComputerDelivery = nil
        save(next)
    }

    /// Face ID, then the computer is in the list of devices, with a copy of every Automatic password and
    /// everything it would otherwise fetch from a Mac, put in the code's response box.
    func approveComputer() async {
        guard !approvingComputer,
              case .asked? = addComputerFlow,
              let join = computerJoin,
              let machine = ComputerJoinCoordinator.joiningComputer(join.request),
              members != nil else { return }
        approvingComputer = true
        defer { approvingComputer = false }
        let context = LAContext()
        defer { context.invalidate() }
        do {
            try await keys.authorize(context, reason: PhoneCopy.faceIDAddComputer(machine.label))
        } catch {
            return
        }
        // If the sheet was closed while Face ID was up, return cleanly without revoking into .expired.
        guard case .asked? = addComputerFlow, let live = computerJoin else { return }
        // After Face ID: the same join, still in time, against the list as it is now (another device may have
        // added a computer with these ids meanwhile). Nothing is kept or sent otherwise.
        guard live.request == join.request, live.request.challenge == join.request.challenge,
              Date() < live.until, var next = members, next.devices.contains(where: { $0.keyID == state.deviceKeyID }),
              !next.machines.contains(where: { $0.machineID == machine.machineID && $0.receivingPublicKey != machine.receivingPublicKey }) else {
            computerJoin = nil
            addComputerFlow = .expired
            return
        }
        addComputerFlow = .adding(name: machine.label)
        do {
            let added = machine
            next.machines.removeAll { $0.machineID == added.machineID }
            next.machines.append(added)
            next.revision += 1
            let signed = try CredentialSealing.signedDocument(next.serializedData(), by: CredentialSealing.keyID(keys.signingPublicKey())) { try keys.signWithDeviceKey($0, context: context) }
            let forComputer = try automaticCopies(for: added, context: context)
            // Decide standalone vs iCloud before writing: only a signed-out iPhone (no iCloud account) commits
            // locally without CloudKit. If iCloud is signed in (even temporarily unavailable), a failed write
            // keeps the computer out of local membership and sends no approval or Automatic copies.
            let availability = await cloudSync.cloud?.availability()
            let requireCloud = cloudSync.cloud != nil && availability != .signedOut
            let mailbox = cloudSync.mailboxes.heldMailboxes[added.machineID] ?? UpdateMailboxWriter.makeUpdateMailbox(for: added.machineID, at: join.relay)
            let status = try approvedJoinStatus(for: added, members: signed, revision: next.revision,
                                                mailbox: mailbox, copies: forComputer)
            let joinRequestBytes = try join.request.serializedData()
            let statusPayload = try status.serializedData()
            let pendingDelivery = PendingComputerDelivery(
                joinRequest: joinRequestBytes,
                joinSecret: join.secret,
                relayURL: join.relay.url,
                machineID: added.machineID,
                machineLabel: added.label,
                statusPayload: statusPayload,
                expiresAt: live.until,
                mailbox: try mailbox.serializedData()
            )
            // Persist recovery context before publishing membership so a crash after share(members:) still resumes.
            var staged = state
            staged.pendingComputerDelivery = pendingDelivery
            guard save(staged) else { throw PeerIntakeFailure(description: "This iPhone could not save the computer being added.") }
            do {
                _ = try await share(members: signed, requireCloud: requireCloud)
            } catch {
                if self.members?.machines.contains(where: { $0.machineID == added.machineID }) != true {
                    clearPendingComputerDelivery()
                }
                throw error
            }
            try cloudSync.mailboxes.keepComputerMailbox(mailbox)
            keepMadeForOthers(forComputer)
            do {
                try await ComputerJoinCoordinator.sendJoinStatus(status, to: join.request, join.keys, at: join.relay)
            } catch RelayBoxError.exists {
                guard await Self.existingApprovalMatches(machineID: added.machineID, keys: join.keys, at: join.relay) else {
                    throw RelayBoxError.exists
                }
            }
            clearPendingComputerDelivery()
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("computer", "added", ["computer": added.label])
            addComputerFlow = .added(name: added.label)
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("computer", "not added", ["error": "\(error)"])
            if let pending = state.pendingComputerDelivery,
               self.members?.machines.contains(where: { $0.machineID == pending.machineID }) == true {
                addComputerFlow = .deliveryFailed(name: pending.machineLabel, reason: PhoneCopy.addComputerDeliveryFailed)
            } else {
                addComputerFlow = .failed(PhoneCopy.addComputerFailed)
            }
        }
        computerJoin = nil
    }

    /// Replays a committed `JoinStatus` from `state.pendingComputerDelivery` without re-prompting Face ID
    /// or bumping the `Members` revision, rebuilding the bundle against current membership and rules so
    /// removed computers or demoted/blocked passwords are never delivered.
    func retryComputerDelivery() async {
        guard !approvingComputer, let pending = state.pendingComputerDelivery else { return }
        guard pending.expiresAt > Date() else {
            clearPendingComputerDelivery()
            addComputerFlow = .expired
            return
        }
        guard let relay = RelayBoxClient(checking: pending.relayURL),
              let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: pending.joinRequest),
              let requestedMachine = ComputerJoinCoordinator.joiningComputer(request),
              let members,
              let listedMachine = members.machines.first(where: {
                  $0.machineID == pending.machineID && $0.receivingPublicKey == requestedMachine.receivingPublicKey
              }),
              let signedMembersBytes = state.members,
              let signedMembers = try? SignedDocument(serializedBytes: signedMembersBytes) else {
            clearPendingComputerDelivery()
            addComputerFlow = .failed(PhoneCopy.addComputerFailed)
            return
        }
        approvingComputer = true
        defer { approvingComputer = false }
        addComputerFlow = .adding(name: listedMachine.label)
        do {
            var status = Agentkeyring_V2_JoinStatus()
            status.state = .approved
            status.members = signedMembers
            // The mailbox held, or the one saved with the approval if a restart came before it was kept.
            let mailbox = try cloudSync.mailboxes.heldMailboxes[listedMachine.machineID]
                ?? Agentkeyring_V2_UpdateMailbox(serializedBytes: pending.mailbox)
            try cloudSync.mailboxes.keepComputerMailbox(mailbox)
            status.mailbox = UpdateMailboxWriter.mailboxGivenToComputer(mailbox)
            status.bundle = lists(for: listedMachine.machineID, copies: .computerOnly)
            if let replyKeyID = try? CredentialSealing.keyID(keys.replyPublicKey()), let catalogue = self.catalogue {
                status.bundle.freshness = try UpdateMailboxWriter.signFreshness(for: listedMachine.machineID, members: members.revision, catalogue: catalogue.revision,
                                                                  signerKeyID: replyKeyID, sign: keys.signReply)
            }
            let codeKeys = ComputerJoinCode(secret: pending.joinSecret, relay: pending.relayURL).keys
            do {
                try await ComputerJoinCoordinator.sendJoinStatus(status, to: request, codeKeys, at: relay)
            } catch RelayBoxError.exists {
                guard await Self.existingApprovalMatches(machineID: listedMachine.machineID, keys: codeKeys, at: relay) else {
                    throw RelayBoxError.exists
                }
            }
            clearPendingComputerDelivery()
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("computer", "added", ["computer": listedMachine.label])
            addComputerFlow = .added(name: listedMachine.label)
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("computer", "delivery retry failed", ["error": "\(error)"])
            addComputerFlow = .deliveryFailed(name: listedMachine.label, reason: PhoneCopy.addComputerDeliveryFailed)
        }
    }

    private static func existingApprovalMatches(machineID: String, keys: ComputerJoinCodeKeys, at relay: RelayBoxClient) async -> Bool {
        guard let existing = try? await relay.fetchRelayBox(box: keys.responseBox, key: keys.responseKey),
              let status = try? Agentkeyring_V2_JoinStatus(serializedBytes: existing.message),
              status.state == .approved,
              let members = try? Members(serializedBytes: status.members.payload) else {
            return false
        }
        return members.machines.contains(where: { $0.machineID == machineID })
    }

    private func refuseComputer() async {
        guard let join = computerJoin, let machine = ComputerJoinCoordinator.joiningComputer(join.request) else { return }
        clearPendingComputerDelivery()
        computerJoin = nil
        addComputerFlow = .notAdded(name: machine.label)
        try? await ComputerJoinCoordinator.sendJoinStatus(ComputerJoinCoordinator.refusedJoinStatus(join.request, join.keys, reply: ""), to: join.request, join.keys, at: join.relay)
    }

    enum BundleCopies { case none, computerOnly }

    /// Everything a computer keeps: the lists, every revision of Members, the push addresses, and the copies
    /// sealed to it. Never Apple Watch's: the Watch keeps its own.
    func lists(for computerID: String, copies: BundleCopies) -> Agentkeyring_V2_Bundle {
        var lists = Agentkeyring_V2_Bundle()
        if let bytes = state.members, let signed = try? SignedDocument(serializedBytes: bytes) { lists.members = signed }
        if let bytes = state.catalogue, let signed = try? SignedDocument(serializedBytes: bytes) { lists.catalogue = signed }
        lists.membersSince = state.membersHistory.compactMap { try? SignedDocument(serializedBytes: $0) }
        lists.pushRegistrations = state.pushRegistrations.keys.sorted().compactMap {
            state.pushRegistrations[$0].flatMap { try? SignedDocument(serializedBytes: $0) }
        }
        lists.copies = copies == .none ? [] : madeForOthers.filter { $0.openerID == computerID }
        return lists
    }
}
