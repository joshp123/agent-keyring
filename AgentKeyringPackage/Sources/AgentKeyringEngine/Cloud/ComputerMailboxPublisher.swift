// Written by AI on 2026.11.27 by model claude opus 5.5; scheduling for both devices added on 2026.11.28 by
// model claude opus 5.5.
//
// Each computer's update mailbox (keyring.proto, "Update mailboxes";
// AgentKeyringSealing/UpdateMailboxWriter.swift) as a Mac and an iPhone both keep it:
// made when either adds a computer, shared with the other devices through
// iCloud, and this device's slot in it written a moment after the lists change
// and once a day while the app runs, so the computer learns every change
// without reaching a device. A computer removed from the list is sent the
// Members that leaves it out, once, and then its mailbox is forgotten.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation

@MainActor
package final class ComputerMailboxPublisher<Host: CloudReplicaHost> {
    /// When this device last wrote each computer's slot.
    package private(set) var written: [String: Date] = [:]
    /// Each mailbox's signed iCloud document, by machine ID, with the mailbox bytes it was made from.
    private var signedDocuments: [String: (raw: Data, signed: Data)] = [:]
    weak var host: Host?
    weak var sync: CloudReplicaSyncCoordinator<Host>?
    private let cloud: (any CloudPipe)?
    private var writing: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?

    init(cloud: (any CloudPipe)?) {
        self.cloud = cloud
    }

    /// Forgets what this launch wrote: on reset, or when this device leaves the list.
    package func forgetWrittenSlots() {
        written = [:]
        signedDocuments = [:]
    }

    func stopMailboxWrites() {
        writing?.cancel(); writing = nil
        refreshing?.cancel(); refreshing = nil
    }

    /// Every computer's mailbox held, by machine ID.
    package var heldMailboxes: [String: Agentkeyring_V2_UpdateMailbox] {
        host.map { $0.replica.mailboxes.compactMapValues { try? Agentkeyring_V2_UpdateMailbox(serializedBytes: $0) } } ?? [:]
    }

    /// A mailbox made here or by another device: kept, and shared in iCloud with the next push. Throws when it
    /// is not whole or could not be saved: a computer must never be approved with a mailbox no device can write.
    package func keepComputerMailbox(_ mailbox: Agentkeyring_V2_UpdateMailbox) throws {
        guard let host, let bytes = Self.wholeMailboxBytes(mailbox) else {
            throw PeerIntakeFailure(description: "A computer's mailbox needs its seed and both tokens.")
        }
        guard host.replica.mailboxes[mailbox.machineID] != bytes else { return }
        guard host.updateReplica({ $0.mailboxes[mailbox.machineID] = bytes }) else {
            throw PeerIntakeFailure(description: "This device could not save the computer's mailbox.")
        }
        sync?.pushCloudSoon()
    }

    /// The mailbox's bytes, if it is a whole mailbox: a computer, its seed and both tokens.
    private static func wholeMailboxBytes(_ mailbox: Agentkeyring_V2_UpdateMailbox) -> Data? {
        guard !mailbox.machineID.isEmpty, mailbox.seed.count == 32, !mailbox.readAuth.isEmpty, !mailbox.writeAuth.isEmpty else { return nil }
        return try? mailbox.serializedData()
    }

    /// A mailbox another device shared in iCloud: kept if a device in the list signed it and it names a computer
    /// in the list. One held already is never replaced from iCloud. True when it was kept.
    func takeCloudMailboxRecord(_ record: CloudRecord, pull: ReplicaPull, me: String) -> Bool {
        guard let host, let members = host.replica.currentMembers, let opener = host.replicaKeyOpener else {
            pull.markRecordForRetry(record.name)
            return false
        }
        switch CloudMailboxDocument.openRecord(record, deviceID: me, members: members, opener: opener) {
        case .retry:
            pull.markRecordForRetry(record.name)
            return false
        case .ignore:
            if members.devices.contains(where: { $0.keyID == record.writer }) { pull.clearRecordRetry(record.name) } else { pull.markRecordForRetry(record.name) }
            return false
        case let .accepted(mailbox):
            pull.clearRecordRetry(record.name)
            guard host.replica.mailboxes[mailbox.machineID] == nil, let bytes = Self.wholeMailboxBytes(mailbox) else { return false }
            return host.updateReplica { $0.mailboxes[mailbox.machineID] = bytes }
        }
    }

    /// iCloud's record of each mailbox held, signed by this device and sealed to every device listed.
    func mailboxCloudRecords(members: Members, writer: String, sealCache: inout CloudSealCache) throws -> [CloudRecord] {
        guard let host else { return [] }
        let recipients = CloudEnvelope.recipients(for: members)
        let mailboxes = host.replica.mailboxes
        return try mailboxes.keys.sorted().compactMap { machineID in
            guard let bytes = mailboxes[machineID], let mailbox = try? Agentkeyring_V2_UpdateMailbox(serializedBytes: bytes) else { return nil }
            let signed: Data
            if let cached = signedDocuments[machineID], cached.raw == bytes {
                signed = cached.signed
            } else {
                signed = try CloudMailboxDocument.signedMailboxDocument(mailbox, signer: host.replicaReplySigner).serializedData()
                signedDocuments[machineID] = (bytes, signed)
            }
            let kind = CloudRecordKind.mailbox(machineID)
            let payload = try sealCache.sealForMembers(name: kind, kind: kind, plaintext: signed, recipients: recipients, members: members)
            return CloudRecord(kind: kind, writer: writer, payload: payload)
        }
    }

    // MARK: Writing slots

    /// The lists changed: every computer's slot is written a moment later, once.
    package func writeMailboxSlotsSoon() {
        guard let host, !host.replica.mailboxes.isEmpty else { return }
        writing?.cancel()
        writing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.writeMailboxSlots(olderThan: nil)
        }
    }

    /// Once a day while the app runs, so a quiet week never pauses a computer's Automatic passwords.
    package func keepMailboxSlotsFresh() {
        guard refreshing == nil else { return }
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                await self?.writeMailboxSlots(olderThan: UpdateMailboxWriter.rewriteAfter)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// This device's slot in each computer's mailbox (`olderThan`: only slots not written for that long). A
    /// listed computer waits while its lists are held (`listsHeldFromComputers`); a computer no longer listed is
    /// sent only the Members that leaves it out, and its mailbox then goes.
    package func writeMailboxSlots(olderThan age: TimeInterval?) async {
        guard let host, let sync, let slotWrite = await host.mailboxSlotWrite(), let members = host.replica.currentMembers,
              let lists = Self.signedMailboxLists(of: host.replica) else { return }
        let holding = sync.listsHeldFromComputers
        for (machineID, mailbox) in heldMailboxes {
            if let age, let last = written[machineID], Date().timeIntervalSince(last) < age { continue }
            let listed = members.machines.contains { $0.machineID == machineID }
            if listed, holding { continue }
            let signer = slotWrite.signer
            let bundle = UpdateMailboxWriter.computerUpdateBundle(for: machineID, lists: lists, copies: slotWrite.copies) {
                try? UpdateMailboxWriter.signFreshness(for: machineID, members: members.revision, catalogue: slotWrite.catalogueRevision,
                                                       signerKeyID: signer.keyID, sign: signer.sign)
            }
            let computer = String(machineID.prefix(16))
            do {
                try await UpdateMailboxWriter.writeMailboxSlot(bundle, to: mailbox, from: slotWrite.deviceID,
                                                               at: UpdateMailboxWriter.mailboxRelay(of: mailbox) ?? slotWrite.relay)
            } catch {
                host.replicaLog.noteDeviceEvent("mailbox", "not-written", ["computer": computer, "reason": "\(error)"])
                continue
            }
            guard !listed else {
                written[machineID] = .now
                host.replicaLog.noteDeviceEvent("mailbox", "written", ["computer": computer])
                continue
            }
            host.replicaLog.noteDeviceEvent("mailbox", "removal-written", ["computer": computer])
            written.removeValue(forKey: machineID)
            await forgetRemovedMailbox(machineID)
        }
    }

    private func forgetRemovedMailbox(_ machineID: String) async {
        host?.updateReplica { $0.mailboxes.removeValue(forKey: machineID) }
        let name = CloudRecordKind.mailbox(machineID)
        guard let cloud, (try? await cloud.deleteCloudRecords([name])) != nil else { return }
        host?.updateReplica { $0.cloudCheckpoint.noteDeleted([name]) }
    }

    private static func signedMailboxLists(of replica: Host.Replica) -> MailboxSignedLists? {
        guard let membersBytes = replica.members, let signedMembers = try? SignedDocument(serializedBytes: membersBytes) else { return nil }
        return MailboxSignedLists(
            members: signedMembers,
            membersHistory: replica.membersHistory.compactMap { try? SignedDocument(serializedBytes: $0) },
            catalogue: replica.catalogue.flatMap { try? SignedDocument(serializedBytes: $0) },
            pushRegistrations: replica.pushRegistrations.keys.sorted().compactMap {
                replica.pushRegistrations[$0].flatMap { try? SignedDocument(serializedBytes: $0) }
            }
        )
    }

    /// A Freshness for a computer, sent with the lists in an answer or a join.
    package func signedFreshness(for machineID: String) -> SignedDocument? {
        guard let host, let members = host.replica.currentMembers else { return nil }
        let signer = host.replicaReplySigner
        return try? UpdateMailboxWriter.signFreshness(for: machineID, members: members.revision,
                                                      catalogue: host.replica.effectiveCatalogue?.revision ?? 0,
                                                      signerKeyID: signer.keyID, sign: signer.sign)
    }
}

/// What this device writes into each computer's mailbox slot: its copies, its identity and signer, the
/// catalogue revision a Freshness vouches for, and the relay used for a mailbox that names none.
package struct MailboxSlotWrite {
    package var copies: [SealedLogin]
    package var deviceID: String
    package var signer: PayloadReplySigner
    package var catalogueRevision: UInt64
    package var relay: RelayBoxClient

    package init(copies: [SealedLogin], deviceID: String, signer: PayloadReplySigner, catalogueRevision: UInt64,
                relay: RelayBoxClient) {
        self.copies = copies
        self.deviceID = deviceID
        self.signer = signer
        self.catalogueRevision = catalogueRevision
        self.relay = relay
    }
}
