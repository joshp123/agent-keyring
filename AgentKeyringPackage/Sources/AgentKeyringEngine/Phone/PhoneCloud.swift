// Written by AI on 2026.11.23 by model claude opus 5.5; edited on 2026.11.28 by model claude opus 5.5.
//
// This iPhone and the user's other devices through his iCloud private database, the same way a Mac does it
// (AgentKeyringEngine/Cloud, CloudReplicaSyncCoordinator). What is the iPhone's own: its lists in one file, its own
// copy of every password and the copies the Mac sealed for its Apple Watch, the copies it seals for other
// devices and computers, its vault folded into one snapshot, and a Mac's or iPhone's join shown once it
// proves the invitation this iPhone left. Changes signed here go to iCloud first (share), so another device's
// newer list is never written over.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

@MainActor
extension PhoneKeyringEngine: CloudReplicaHost {
    // MARK: Sharing what this iPhone signed

    /// A catalogue this iPhone signed: to iCloud unless a newer one is there (that one is then taken, and the
    /// change must be made again). Then kept here; iCloud out of reach has it with the next write.
    func share(catalogue signed: SignedDocument) async throws {
        let signedBytes = try signed.serializedData()
        if let cloud = cloudSync.cloud, await cloud.availability() == .available {
            switch await cloudSync.confirmCloudMembers() {
            case .owned:
                if let current = members, case let .theirs(opened) = try await cloudSync.writeCloudCatalogue(signedBytes, members: current),
                   opened?.plaintext != signedBytes {
                    throw PhoneApprovalError.notAllowed("Another device changed the list first.")
                }
            case .conflict:
                throw PhoneApprovalError.notAllowed("Couldn't confirm this keyring's device list in iCloud. Try again.")
            case .unreachable:
                break
            }
        }
        try receiveSignedCatalogue(signedBytes).requireTaken()
        cloudSync.pushCloudSoon()
    }

    /// New Members this iPhone signed, as `share(catalogue:)`. True if they are in iCloud.
    /// When `requireCloud` is true, an unreachable iCloud write throws without adopting the list locally.
    @discardableResult
    func share(members signed: SignedDocument, requireCloud: Bool = false) async throws -> Bool {
        let current = members
        let revision = try CredentialSealing.verifySignedMembers(signed, current: current).revision
        let bytes = try signed.serializedData()
        let history = state.membersAncestry
        let payload = try CloudMembers.payload(current: bytes, history: state.membersHistory)
        switch await cloudSync.writeSharedRecord(CloudRecordKind.members, payload: payload, mayReplace: { held in
            current.map { CloudMembers.mayReplace(held, with: revision, members: $0, history: history) } ?? true
        }) {
        case let .theirs(theirs):
            await cloudSync.receiveCloudMembers(theirs)
            cloudSync.noteAnotherKeyring(theirs, members: current, history: history)
            throw PhoneApprovalError.notAllowed("Another device changed the list of devices first.")
        case .written:
            try receiveSignedMembers(bytes).requireTaken()
            updateReplica {
                $0.cloudAcceptedMembers = bytes
                $0.cloudCheckpoint.noteWritten([CloudRecordKind.members])
            }
            cloudSync.pushCloudSoon()
            return true
        case .unreachable:
            if requireCloud {
                throw PhoneApprovalError.notAllowed("Couldn't save the updated device list to iCloud. Try again.")
            }
            try receiveSignedMembers(bytes).requireTaken()
            cloudSync.pushCloudSoon()
            return false
        }
    }

    /// CloudKit's push: something in iCloud changed.
    public func cloudChanged() async { await refresh() }

    // MARK: The iPhone as a replica

    package var replica: PhoneSavedState { state }

    @discardableResult
    package func updateReplica(_ change: (inout PhoneSavedState) -> Void) -> Bool {
        var next = state
        change(&next)
        guard next != state else { return true }
        return save(next)
    }

    package var replicaReadable: Bool { !stateFileLocked }
    package var replicaDeviceID: String? { state.deviceKeyID }
    package var replicaSigningPublicKey: Data? { try? keys.signingPublicKey() }
    package var replicaMachineID: String? { nil }
    package var replicaKeyOpener: CloudEnvelope.KeyOpener? { try? keys.cloudKeyOpener() }
    package var replicaReplySigner: PayloadReplySigner { sealSigner }
    package var replicaLog: KeyringDiagnosticLog { .iPhone }

    /// Another device's vault, folded into this iPhone's.
    package func receivePeerVault(_ vault: CredentialVault) async -> Bool {
        let current = ownVaultSnapshot ?? Self.emptyVaultSnapshot
        let folded = current.folding(vault)
        guard folded.vault != current.vault else { return true }
        return saveOwnVaultSnapshot(folded)
    }

    /// Its own copies, and those another device sealed for its Apple Watch, which go to the Watch from here.
    package func takesCloudCopies(for recipient: String) -> Bool {
        recipient == state.deviceKeyID || recipient == listedWatch?.keyID
    }

    package func receiveCheckedCloudCopies(_ copies: [SealedLogin], for recipient: String) async -> CloudCopiesIntake {
        guard recipient == state.deviceKeyID else { return keepWatchCopiesFromOthers(copies) ? .kept : .notSaved }
        do { try keepOwnSealedCopies(copies) } catch { return .notSaved }
        return .kept
    }

    /// Requests to join this iPhone's list, and the one waiting here taken away by its device.
    package func receiveCloudJoins(from pull: ReplicaPull) async {
        if let cloud = cloudSync.cloud, let me = state.deviceKeyID {
            for record in pull.changes.records where record.writer != me && record.kind.hasPrefix("join-") {
                await takeCloudJoin(record, from: cloud)
            }
        }
        if let asking = pendingJoinName, pull.deleted.contains(asking) { clearDeviceJoin() }
    }

    package func cloudSealedRecordsTaken() async { refreshPasswordsCopy() }

    package func cloudPullFinished(peerChanges: Int) {
        if peerChanges > 0 { onListsChanged?() }
    }

    package func ownCloudVault() async -> CredentialVault? { ownVaultSnapshot?.vault }

    /// This iPhone's push address and its Apple Watch's, which only this iPhone signs.
    package func pushRegistrationsWrittenHere(in members: Members) -> [String] {
        guard let me = state.deviceKeyID else { return [] }
        return [me] + members.devices.filter { $0.kind == .watch }.map(\.keyID)
    }

    /// Apple Watch's copies go to it from this iPhone directly, never through iCloud. Enrolled computers'
    /// Automatic copies go beside other devices' copies, so a Mac picks up copies sealed during this iPhone's one
    /// Face ID without a second Touch ID.
    package func cloudCopiesToShare(in members: Members) async throws -> [(recipient: String, copies: [SealedLogin])] {
        let made = madeForOthers
        let recipients = members.devices.filter { $0.keyID != state.deviceKeyID && $0.kind != .watch }.map(\.keyID)
            + members.machines.map(\.machineID)
        return recipients.map { recipient in (recipient, made.filter { $0.openerID == recipient }) }
    }

    /// This iPhone's own request to join, once it is in a list.
    package func endedCloudJoinNames(in members: Members) -> [String] {
        state.deviceKeyID.map { [CloudRecordKind.join($0)] } ?? []
    }

    package func mailboxSlotWrite() async -> MailboxSlotWrite? {
        guard let me = state.deviceKeyID else { return nil }
        return MailboxSlotWrite(copies: madeForOthers, deviceID: me, signer: sealSigner,
                                catalogueRevision: catalogue?.revision ?? 0, relay: .configured)
    }

    package func cloudSyncStateChanged(from previous: CloudSyncState) { publish() }
}
