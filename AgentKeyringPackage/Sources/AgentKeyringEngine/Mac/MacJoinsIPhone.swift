// Written by AI on 2026.11.24 by model claude opus 5.5; joining another Mac too, the same day.
//
// A new Mac joining a list that started on an iPhone or another Mac, through
// iCloud: the mirror of an iPhone joining a Mac (MacCloud.swift,
// takeCloudJoin). Welcome offers Connect when iCloud Keychain holds an iPhone's
// or a Mac's invitation and iCloud holds that device's list. Connect puts two
// requests in iCloud, one as an approving device and one as the computer this
// Mac's agents run on, each proving the invitation. The inviter adds both with
// one Face ID or Touch ID; this Mac takes the list only from the revision that
// names it with its own keys, signed by the device whose invitation it proved,
// each later one checked against the one before.

#if os(macOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

/// Where joining an iPhone's list stands, as Welcome shows it.
public enum JoiningIPhone: Equatable, Sendable {
    /// iCloud holds an iPhone's invitation and list: Connect is offered.
    case found(name: String)
    /// He clicked Connect: the requests wait in iCloud for the iPhone.
    case asking(name: String)
    /// The iPhone took the requests away without adding this Mac, or ten minutes passed.
    case notAdded(name: String)
    /// This Mac is in the iPhone's list; its copies arrive from iCloud.
    case joined(name: String)
}

@MainActor
extension MacSyncCoordinator {
    /// Welcome looks every few seconds: an iPhone's invitation in iCloud Keychain, and a list in iCloud in which
    /// that invitation's device is an iPhone. Only for a Mac with no list of its own.
    public func lookForIPhone() async {
        guard members == nil, let cloud = cloudSync.cloud else { return }
        switch joiningIPhone {
        case .asking?, .joined?, .notAdded?: return
        default: break
        }
        let found = await iPhoneList(in: cloud)
        guard members == nil, joiningIPhone.map({ if case .found = $0 { true } else { false } }) ?? true else { return }
        iPhoneInvite = found?.invite
        joiningIPhone = found.map { .found(name: $0.name) }
    }

    private func iPhoneList(in cloud: any CloudPipe) async -> (invite: Agentkeyring_V2_JoinInvite, name: String)? {
        guard let invite = environment.invitationStore.read(), !invite.secret.isEmpty, !invite.inviterKeyID.isEmpty,
              invite.inviterKeyID != keys.deviceKeyID,
              invite.expiresUnixSeconds > Int64(Date.now.timeIntervalSince1970),
              await cloud.availability() == .available,
              let held = try? await cloud.fetchCloudPayload(named: CloudRecordKind.members), let newest = CloudMembers.revisions(held).last,
              let list = try? CredentialSealing.verifySignedMembers(newest, current: nil),
              let inviter = list.devices.first(where: { $0.keyID == invite.inviterKeyID && ($0.kind == .iphone || $0.kind == .mac) })
        else { return nil }
        return (invite, inviter.label)
    }

    /// Connect, or Ask Again, with the iPhone's invitation as iCloud Keychain holds it now.
    public func connectToIPhone() {
        guard members == nil, let cloud = cloudSync.cloud, askingIPhone == nil, let found = iPhoneInvite else { return }
        let invite = environment.invitationStore.read().flatMap { $0.inviterKeyID == found.inviterKeyID && !$0.secret.isEmpty ? $0 : nil } ?? found
        let name: String
        switch joiningIPhone {
        case let .found(found)?, let .notAdded(found)?: name = found
        default: return
        }
        joiningIPhone = .asking(name: name)
        // Read iCloud every few seconds until the copies have had time to arrive after the iPhone adds this Mac.
        cloudSync.pollQuicklyUntil = .now.addingTimeInterval(Self.joinLasts + 120)
        iphoneJoinGeneration &+= 1
        let attempt = iphoneJoinGeneration
        let priorCleanup = iphoneJoinCleanup
        askingIPhone = Task { [weak self] in
            await priorCleanup?.value
            guard !Task.isCancelled, let self, self.iphoneJoinGeneration == attempt else { return }
            await self.askIPhone(invite, name: name, cloud: cloud, attempt: attempt)
            if self.iphoneJoinGeneration == attempt {
                self.askingIPhone = nil
            }
        }
    }

    /// Cancel while waiting: the requests go, and Connect is offered again.
    public func cancelJoiningIPhone() {
        guard case let .asking(name)? = joiningIPhone else { return }
        iphoneJoinGeneration &+= 1
        askingIPhone?.cancel()
        askingIPhone = nil
        joiningIPhone = .found(name: name)
        let names = iPhoneJoinNames
        let previous = iphoneJoinCleanup
        iphoneJoinCleanup = Task { [cloud = cloudSync.cloud] in
            await previous?.value
            try? await cloud?.deleteCloudRecords(names)
        }
    }

    private var iPhoneJoinNames: [String] { [CloudRecordKind.join(keys.deviceKeyID), CloudRecordKind.join(keys.machineID)] }

    /// Puts the two requests in iCloud, the computer's first (the iPhone reads it once it sees the device's),
    /// and every three seconds reads whether the iPhone's list now names this Mac. The iPhone takes the
    /// requests away when it adds this Mac and when it does not: the request is read before the list, so a
    /// list written just before the request went is still seen.
    private func askIPhone(_ invite: Agentkeyring_V2_JoinInvite, name: String, cloud: any CloudPipe, attempt: UInt64) async {
        var computer = Agentkeyring_V2_JoinRequest()
        computer.machine = keys.machine
        computer.proof = CredentialSealing.joinProof(secret: invite.secret, joining: computer)
        var device = Agentkeyring_V2_JoinRequest()
        device.device = keys.device
        device.proof = CredentialSealing.joinProof(secret: invite.secret, joining: device)
        let me = keys.deviceKeyID
        do {
            try await cloud.writeCloudRecords([CloudRecord(kind: CloudRecordKind.join(keys.machineID), writer: me, payload: computer.serializedData())])
            try await cloud.writeCloudRecords([CloudRecord(kind: CloudRecordKind.join(me), writer: me, payload: device.serializedData())])
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "asked-iphone", ["route": "icloud"])
            let asked = Date.now
            while asked.addingTimeInterval(Self.joinLasts) > .now {
                let gone = Date.now.timeIntervalSince(asked) > 15 ? try await cloud.fetchCloudPayload(named: CloudRecordKind.join(me)) == nil : false
                if let held = try await cloud.fetchCloudPayload(named: CloudRecordKind.members), await adoptIPhoneList(held, inviter: invite.inviterKeyID) {
                    try? await cloud.deleteCloudRecords(iPhoneJoinNames)
                    guard iphoneJoinGeneration == attempt else { return }
                    joiningIPhone = .joined(name: name)
                    // The iPhone's catalogue, vault and copies were passed over while this Mac was in no list.
                    cloudSync.readWholeCloudNext()
                    cloudSync.pullCloudSoon()
                    return
                }
                if gone { break }
                try await Task.sleep(for: .seconds(3))
            }
        } catch is CancellationError {
            return
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "iphone-not-asked", ["reason": "\(error)"])
        }
        guard iphoneJoinGeneration == attempt else { return }
        try? await cloud.deleteCloudRecords(iPhoneJoinNames)
        guard iphoneJoinGeneration == attempt else { return }
        joiningIPhone = .notAdded(name: name)
        KeyringDiagnosticLog.mac.noteDeviceEvent("join", "iphone-not-added", [:])
    }

    /// Takes an iPhone's list from iCloud, from the first revision that names this Mac with its own keys and is
    /// signed by `inviter`, an iPhone in it, each later revision checked against the one before. True once
    /// this Mac has the list.
    func adoptIPhoneList(_ payload: Data, inviter: String) async -> Bool {
        guard members == nil else { return members?.devices.contains { $0.keyID == keys.deviceKeyID } == true }
        let me = keys.device
        let revisions = CloudMembers.revisions(payload)
        guard let first = revisions.firstIndex(where: { revision in
                  revision.signerKeyID == inviter && (try? Agentkeyring_V2_Members(serializedBytes: revision.payload))?.devices.contains {
                      $0.keyID == me.keyID && $0.signingPublicKey == me.signingPublicKey && $0.openingPublicKey == me.openingPublicKey
                  } == true
              }),
              let anchor = try? CredentialSealing.verifySignedMembers(revisions[first], current: nil),
              anchor.devices.contains(where: { $0.keyID == inviter && ($0.kind == .iphone || $0.kind == .mac) }) else { return false }
        for revision in revisions[first...] {
            _ = await receiveSignedMembers((try? revision.serializedData()) ?? Data())
        }
        guard members != nil else { return false }
        KeyringDiagnosticLog.mac.noteDeviceEvent("join", "joined-iphone", ["revision": "\(members?.revision ?? 0)"])
        return true
    }
}
#endif
