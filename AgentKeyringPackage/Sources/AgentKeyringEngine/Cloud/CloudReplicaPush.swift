// Written by AI on 2026.11.28 by model claude opus 5.5.
//
// What a Mac or an iPhone writes to iCloud. The records every device shares, Members and the catalogue, are
// written only over an older revision this device follows; when iCloud keeps its own, that one is taken in
// instead. Then the records only this device writes: push addresses, computers' mailboxes, its vault, its
// side of a contest and the copies it sealed for each other device and computer. Copies and requests to join
// that are no longer wanted go.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

extension CloudReplicaSyncCoordinator {
    /// Everything this device keeps in iCloud, from the lists iCloud took: after a conflict, from the one it kept.
    package func pushCloudNow() async {
        guard let host, let cloud, host.replicaReadable, let me = host.replicaDeviceID,
              host.replica.currentMembers?.devices.contains(where: { $0.keyID == me }) == true else { return }
        // Removals still go to computers at once; listed computers wait until iCloud has accepted the lists.
        defer { mailboxes.writeMailboxSlotsSoon() }
        guard state != .signedOut, await confirmCloudMembers() == .owned, let acceptedBytes = host.replica.members,
              let accepted = host.replica.currentMembers, accepted.devices.contains(where: { $0.keyID == me }) else { return }
        // Members that change during a wait (a device removed) end this push: nothing is sealed to the old list.
        // The change pushes again.
        let membersUnchanged = { host.replica.members == acceptedBytes }
        do {
            if let submitted = host.replica.catalogue, host.replica.effectiveCatalogue != nil {
                guard try await writeCloudCatalogue(submitted, members: accepted) != .unreachable else { return }
            } else {
                host.updateReplica { $0.cloudAcceptedCatalogue = nil }
            }
            guard membersUnchanged() else { pushCloudSoon(); return }
            let (records, stale) = try await ownCloudRecords(members: accepted, me: me)
            guard membersUnchanged() else { pushCloudSoon(); return }
            try await cloud.writeCloudRecords(records)
            host.updateReplica { $0.cloudCheckpoint.noteWritten(records.map(\.name)) }
            try await cloud.deleteCloudRecords(stale)
            host.updateReplica { $0.cloudCheckpoint.noteDeleted(stale) }
            moveSyncState(to: .syncing)
        } catch {
            host.replicaLog.noteDeviceEvent("cloud", "push-failed", ["reason": "\(error)"])
        }
    }

    /// The records only this device writes, and the names of its records to take out of iCloud.
    private func ownCloudRecords(members: Members, me: String) async throws -> (records: [CloudRecord], stale: [String]) {
        guard let host else { return ([], []) }
        let recipients = CloudEnvelope.recipients(for: members)
        var records = try mailboxes.mailboxCloudRecords(members: members, writer: me, sealCache: &sealCache)
        records += host.pushRegistrationsWrittenHere(in: members).compactMap { device in
            host.replica.pushRegistrations[device].map { CloudRecord(kind: CloudRecordKind.push(device), writer: me, payload: $0) }
        }
        if let vault = await host.ownCloudVault() {
            let kind = CloudRecordKind.vault(me)
            let signed = try signedVaultDocument(vault, signer: host.replicaReplySigner)
            records.append(CloudRecord(kind: kind, writer: me, payload: try sealCache.sealForMembers(
                name: kind, kind: kind, plaintext: signed, recipients: recipients, members: members)))
        }
        let known = host.replica.cloudCheckpoint.knownNames
        var stale: [String] = []
        // While a contest is held, this device's own side goes beside it for the others to merge.
        let contested = CloudRecordKind.contested(me)
        if host.replica.catalogueContested, let own = host.replica.ownContestedCatalogue(signedBy: me) {
            records.append(CloudRecord(kind: contested, writer: me, payload: try sealCache.sealForMembers(
                name: contested, kind: contested, plaintext: own, recipients: recipients, members: members)))
        } else if known.contains(contested) {
            stale.append(contested)
        }
        var copyRecipients: Set<String> = []
        for (recipient, copies) in try await host.cloudCopiesToShare(in: members) where !copies.isEmpty && !copyRecipients.contains(recipient) {
            copyRecipients.insert(recipient)
            let parts = try CloudCopies.records(copies, for: recipient, writer: me)
            records += parts
            stale += CloudCopies.stale(known, recipient: recipient, writer: me, written: parts.count)
        }
        // Copies for a device removed from the list, or one this device now holds none for, go too.
        stale += CloudCopies.orphaned(known, writer: me, keeping: copyRecipients)
        stale += host.endedCloudJoinNames(in: members).filter(known.contains)
        return (records, stale)
    }

    /// Confirms iCloud holds this keyring's Members, writing this device's or taking a newer revision, before
    /// anything else is written: an offline device never writes over another keyring.
    package func confirmCloudMembers() async -> CloudMembersOwnership {
        guard let host, let me = host.replicaDeviceID, let members = host.replica.currentMembers,
              members.devices.contains(where: { $0.keyID == me }), let submitted = host.replica.members,
              let payload = try? CloudMembers.payload(current: submitted, history: host.replica.membersHistory) else { return .unreachable }
        let history = host.replica.membersAncestry
        let revision = members.revision
        switch await writeSharedRecord(CloudRecordKind.members, payload: payload, mayReplace: {
            CloudMembers.mayReplace($0, with: revision, members: members, history: history)
        }) {
        case .written:
            // The exact snapshot iCloud accepted, never a newer local edit made during the write.
            host.updateReplica {
                $0.cloudAcceptedMembers = submitted
                $0.cloudCheckpoint.noteWritten([CloudRecordKind.members])
            }
            return .owned
        case let .theirs(theirs):
            await receiveCloudMembers(theirs)
            noteAnotherKeyring(theirs, members: members, history: history)
            // Owned only when iCloud's newest revision is the one held now: never from what a save that may have
            // failed left in `cloudAcceptedMembers`.
            let inCloud = CloudMembers.revisions(theirs).last.flatMap { try? $0.serializedData() }
            let listed = host.replica.currentMembers?.devices.contains { $0.keyID == me } == true
            return inCloud != nil && inCloud == host.replica.members && listed ? .owned : .conflict
        case .unreachable:
            return .unreachable
        }
    }

    /// Writes a record every device shares, unless `mayReplace` says the one in iCloud must stay: one of the
    /// same or a later revision signed by one of the user's devices, or another keyring's list.
    package func writeSharedRecord(_ kind: String, payload: Data, mayReplace: @escaping @Sendable (Data) -> Bool) async -> CloudSharedWrite {
        guard let host, let cloud, let me = host.replicaDeviceID, await cloud.availability() == .available else { return .unreachable }
        do {
            let theirs = try await cloud.writeCloudRecordIfNewer(CloudRecord(kind: kind, writer: me, payload: payload), isNewer: mayReplace)
            return theirs.map(CloudSharedWrite.theirs) ?? .written
        } catch {
            host.replicaLog.noteDeviceEvent("cloud", "not-shared", ["kind": kind, "reason": "\(error)"])
            return .unreachable
        }
    }

    /// Writes this catalogue unless iCloud's must stay (`CloudCatalogue.givesWay`): that one is then taken or
    /// merged in. Either way, whether iCloud holds this device's is noted.
    package func writeCloudCatalogue(_ submitted: Data, members: Members) async throws -> CloudCatalogueWrite {
        guard let host, let me = host.replicaDeviceID, let opener = host.replicaKeyOpener else { return .unreachable }
        let recipients = CloudEnvelope.recipients(for: members)
        let sealed = try sealCache.sealForMembers(name: CloudRecordKind.catalogue, kind: CloudRecordKind.catalogue, plaintext: submitted,
                                                  recipients: recipients, members: members)
        let offered = SubmittedCatalogue(signedBytes: submitted, recipients: recipients)
        switch await writeSharedRecord(CloudRecordKind.catalogue, payload: sealed, mayReplace: {
            CloudCatalogue.shouldReplace($0, with: offered, members: members, deviceID: me, opener: opener)
        }) {
        case .written:
            host.updateReplica {
                $0.cloudAcceptedCatalogue = submitted
                $0.cloudCheckpoint.noteWritten([CloudRecordKind.catalogue])
            }
            return .written
        case .unreachable:
            return .unreachable
        case let .theirs(theirs):
            let retryCatalogue: () -> Void = {
                host.updateReplica {
                    $0.cloudCheckpoint.retrying.insert(CloudRecordKind.catalogue)
                    $0.cloudAcceptedCatalogue = nil
                }
            }
            guard let opened = CloudEnvelope.openCloudEnvelope(theirs, expectedKind: CloudRecordKind.catalogue, deviceID: me, opener: opener) else {
                retryCatalogue()
                return .theirs(nil)
            }
            if opened.plaintext != submitted, case .notSaved = await host.receiveSignedCatalogue(opened.plaintext) {
                retryCatalogue()
                return .theirs(opened)
            }
            host.updateReplica {
                $0.cloudCheckpoint.retrying.remove(CloudRecordKind.catalogue)
                $0.noteCloudCatalogue(opened)
            }
            return .theirs(opened)
        }
    }

    /// iCloud kept another keyring's list of devices, set up while this device was offline: it stays, and this
    /// device's is not written over it.
    package func noteAnotherKeyring(_ theirs: Data, members: Members?, history: [Data]) {
        guard let host, let members, CloudMembers.isAnotherKeyring(theirs, members: members, history: history),
              host.replica.currentMembers?.revision == members.revision else { return }
        host.replicaLog.noteDeviceEvent("cloud", "members-not-written", ["reason": "iCloud holds another keyring's list of devices"])
    }
}
