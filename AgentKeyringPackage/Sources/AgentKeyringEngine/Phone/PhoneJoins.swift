// Written by AI on 2026.11.24 by model claude opus 5.5.
//
// A new Mac or iPhone joining this iPhone's list through iCloud: the mirror of
// this iPhone joining a Mac (MacCloud.swift, takeCloudJoin). This iPhone keeps
// an invitation in iCloud Keychain while it holds the lists, shows a join from
// iCloud only if it proves that invitation, and after Face ID lists the device
// in Members with a copy of every password sealed to it. A Mac also asks to be
// listed as the computer its own agents run on, in a second request with the
// same TLS key.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Security

extension PhoneKeyringEngine {
    // MARK: The invitation in iCloud Keychain

    /// The invitation this iPhone left, while it has not run out.
    var ownInvitation: Agentkeyring_V2_JoinInvite? {
        guard let me = state.deviceKeyID, let bytes = state.invitation, let invite = try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes),
              invite.inviterKeyID == me, invite.expiresUnixSeconds > Int64(Date().timeIntervalSince1970) else { return nil }
        return invite
    }

    /// Keeps an invitation in iCloud Keychain while this iPhone holds the lists, so a new Mac or iPhone can
    /// find it. One left by a device in the list (the Mac this iPhone joined) always stays. One left by a
    /// device not in it, such as a new Mac, is replaced: that Mac can then find this iPhone. This iPhone's own
    /// stays while it has a day left, unless a join used it (`replacing`).
    func leaveInvitation(replacing: Bool = false) {
        guard let me = state.deviceKeyID, let members, let mine = members.devices.first(where: { $0.keyID == me }) else { return }
        let current = joinCard()
        if let current, !current.inviterKeyID.isEmpty, current.inviterKeyID != me,
           members.devices.contains(where: { $0.keyID == current.inviterKeyID }) { return }
        if !replacing, let current, let own = ownInvitation, current == own,
           own.expiresUnixSeconds > Int64(Date().timeIntervalSince1970) + 86400 { return }
        var invite = Agentkeyring_V2_JoinInvite()
        invite.inviterKeyID = me
        invite.inviterLabel = mine.label
        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        invite.secret = secret
        invite.expiresUnixSeconds = Int64(Date().timeIntervalSince1970) + 7 * 86400
        guard let bytes = try? invite.serializedData() else { return }
        let left = invitationStore.write(invite)
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("invitation", left ? "left" : "not left")
        guard left else { return }
        var next = state
        next.invitation = bytes
        save(next)
    }

    // MARK: A device asking to join

    /// A join from iCloud, kept to be shown once checked.
    func takeCloudJoin(_ record: CloudRecord, from cloud: any CloudPipe) async {
        guard let join = await checkedJoin(record, from: cloud), state.deviceJoin?.device != join.device else { return }
        var next = state
        next.deviceJoin = join
        save(next)
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "asked through iCloud", ["joiner": String(record.writer.prefix(16))])
    }

    /// A Mac's or iPhone's join, if it proves this iPhone's invitation and was asked in the last ten minutes. A
    /// Mac's needs its second request too, naming the computer its agents run on: written first, with the same
    /// TLS key, proving the same invitation.
    private func checkedJoin(_ record: CloudRecord, from cloud: any CloudPipe) async -> PendingDeviceJoin? {
        guard let me = state.deviceKeyID, let members, let invite = ownInvitation, record.updatedAt.addingTimeInterval(600) > Date(),
              let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: record.payload), case let .device(device)? = request.joining,
              device.kind == .mac || device.kind == .iphone, device.keyID == record.writer, device.keyID != me,
              device.keyID == CredentialSealing.keyID(device.signingPublicKey),
              (try? P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)) != nil,
              (try? P256.KeyAgreement.PublicKey(x963Representation: device.noticePublicKey)) != nil,
              CredentialSealing.joinProof(secret: invite.secret, joining: request) == request.proof,
              !members.devices.contains(where: { $0.keyID == device.keyID && $0.openingPublicKey == device.openingPublicKey }) else { return nil }
        guard device.kind == .mac else { return PendingDeviceJoin(device: record.payload, machine: nil, asked: record.updatedAt) }
        let machineID = CredentialSealing.keyID(device.tlsPublicKey)
        guard !device.tlsPublicKey.isEmpty, let held = try? await cloud.fetchCloudRecord(named: CloudRecordKind.join(machineID)),
              let second = try? Agentkeyring_V2_JoinRequest(serializedBytes: held.payload), case let .machine(machine)? = second.joining,
              machine.machineID == machineID, machine.tlsPublicKey == device.tlsPublicKey,
              (try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)) != nil,
              CredentialSealing.joinProof(secret: invite.secret, joining: second) == second.proof else {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "refused", ["reason": "a Mac's join without its computer's"])
            return nil
        }
        return PendingDeviceJoin(device: record.payload, machine: held.payload, asked: record.updatedAt)
    }

    /// The join waiting, as Home shows it.
    var deviceJoinShown: PhoneDeviceJoin? {
        if let addingDevice { return .adding(name: addingDevice) }
        guard let (device, _) = pendingJoin, let asked = state.deviceJoin?.asked, asked.addingTimeInterval(600) > Date() else { return nil }
        return .asked(name: device.label, isMac: device.kind == .mac)
    }

    /// The device waiting to join, and a Mac's computer.
    var pendingJoin: (Agentkeyring_V2_Device, Agentkeyring_V2_Machine?)? {
        guard let join = state.deviceJoin, let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: join.device),
              case let .device(device)? = request.joining else { return nil }
        let second = join.machine.flatMap { try? Agentkeyring_V2_JoinRequest(serializedBytes: $0) }
        guard case let .machine(machine)? = second?.joining else { return (device, nil) }
        return (device, machine)
    }

    /// The name of the waiting join's record in iCloud: the device takes it away when it stops asking.
    var pendingJoinName: String? { pendingJoin.map { CloudRecordKind.join($0.0.keyID) } }

    func clearDeviceJoin() {
        guard state.deviceJoin != nil else { return }
        var next = state
        next.deviceJoin = nil
        save(next)
    }

    /// On coming to the front: a join kept from before is dropped if it ran out or its device stopped asking.
    func recheckDeviceJoin() async {
        guard let join = state.deviceJoin, let name = pendingJoinName, let cloud = cloudSync.cloud else { return }
        if join.asked.addingTimeInterval(600) <= Date() { return clearDeviceJoin() }
        do {
            if try await cloud.fetchCloudRecord(named: name) == nil { clearDeviceJoin() }
        } catch {
            // iCloud could not say whether the device still asks: the join stays until its ten minutes run out.
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "recheck not read", ["error": "\(error)"])
        }
    }

    /// The join is the one shown, within its ten minutes, and its device still holds the exact request in iCloud.
    private func checkStillAsking(_ join: PendingDeviceJoin, _ name: String) async throws {
        guard let cloud = cloudSync.cloud, let held = try await cloud.fetchCloudRecord(named: name),
              held.payload == join.device,
              state.deviceJoin == join,
              join.asked.addingTimeInterval(600) > Date() else {
            if state.deviceJoin == join { clearDeviceJoin() }
            throw PhoneApprovalError.notAllowed("This request to join is no longer waiting.")
        }
    }

    /// Add, after Face ID: the device is listed in Members, a Mac also as a computer, with a copy of every
    /// password sealed to it, shared through iCloud, and the invitation it used is replaced. Don't Add takes
    /// its requests away, which it reads as not added; the invitation stays, so Ask Again works at once.
    public func answerDeviceJoin(add: Bool) async throws {
        guard let join = state.deviceJoin, let (device, machine) = pendingJoin else { return }
        let names = [CloudRecordKind.join(device.keyID)] + (machine.map { [CloudRecordKind.join($0.machineID)] } ?? [])
        guard add else {
            clearDeviceJoin()
            try? await cloudSync.cloud?.deleteCloudRecords(names)
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "not added", ["joiner": String(device.keyID.prefix(16))])
            return
        }
        guard join.asked.addingTimeInterval(600) > Date() else {
            clearDeviceJoin()
            throw PhoneApprovalError.notAllowed("This request to join ran out.")
        }
        let context = LAContext()
        defer { context.invalidate() }
        try await keys.authorize(context, reason: PhoneCopy.faceIDAddDevice(device.label))
        guard state.deviceJoin == join, var next = members, let catalogue else { return }
        try await checkStillAsking(join, names[0])
        addingDevice = device.label
        publish()
        defer { addingDevice = nil; publish() }
        // Every password this iPhone holds a current copy of, opened once with this Face ID and sealed to the
        // new device away from the main thread.
        let held = ownCopies
        let copies = catalogue.logins.filter(\.holdsSecret).compactMap { login -> SealedLogin? in
            guard let copy = held[login.loginID], copy.version == login.version,
                  (try? CredentialSealing.verifySealedLogin(copy, members: next, listed: login)) != nil else { return nil }
            return copy
        }
        let key = try P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)
        let open = try keys.opener(context: context)
        let sign = try keys.replySigner()
        let replyKeyID = CredentialSealing.keyID(try keys.replyPublicKey())
        let deviceID = device.keyID
        let sealed = try await Task.detached {
            let signer = PayloadReplySigner(keyID: replyKeyID, sign: sign)
            return try copies.map { try CredentialSealing.sealLogin(open($0), version: $0.version, to: key, openerID: deviceID, signer: signer) }
        }.value
        next.devices.removeAll { $0.keyID == device.keyID }
        next.devices.append(device)
        // A Mac's computer half carries the device's own TLS key, so removing either removes both.
        if var machine, !machine.tlsPublicKey.isEmpty, machine.tlsPublicKey == device.tlsPublicKey {
            // One name, so Devices lists the Mac once, as on a Mac that started the list itself.
            machine.label = device.label
            next.machines.removeAll { $0.machineID == machine.machineID }
            next.machines.append(machine)
        }
        next.revision += 1
        // Sealing took a while: the device must still be asking, in time, before the list naming it is signed.
        try await checkStillAsking(join, names[0])
        let signed = try CredentialSealing.signedDocument(next.serializedData(), by: CredentialSealing.keyID(keys.signingPublicKey())) { try keys.signWithDeviceKey($0, context: context) }
        // Kept first, so the write that shares the new list also writes its copies.
        keepMadeForOthers(sealed)
        let inCloud = try await share(members: signed)
        clearDeviceJoin()
        leaveInvitation(replacing: true)
        if inCloud { try? await cloudSync.cloud?.deleteCloudRecords(names) }
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "added", ["joiner": String(device.keyID.prefix(16)), "copies": "\(sealed.count)"])
    }
}
