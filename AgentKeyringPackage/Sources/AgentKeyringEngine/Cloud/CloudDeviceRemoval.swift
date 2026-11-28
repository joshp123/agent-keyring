// Written by AI on 2026.11.28 by model claude opus 5.5.
//
// Removing a device, the one way a Mac and an iPhone both do it, after the user's Touch ID or Face ID. The
// next Members leaves the device out (a Mac whole: its approving device and the computer its agents run on
// share one TLS key), and the next catalogue is signed from the merge, so a newer Blocked rule from the
// departing device is never lost. Both go to iCloud in one transaction, each only over the revision the
// removal started from, so a removal by another device meanwhile is never reversed. When another device
// changed either first, the removal is made once more against what it changed. Removing only a computer
// needs no new catalogue.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

/// Why a device could not be removed. Each device words it for its own screens.
enum CloudDeviceRemovalError: Error, Equatable, Sendable {
    /// Another device removed this one first.
    case thisDeviceRemoved
    case cloudUnreachable
    case membersChangedFirst
    case catalogueChangedFirst
    /// With no iCloud: the list of devices changed on this device while the removal was signed.
    case membersChangedWhileRemoving
}

/// The catalogue a removal is signed from: the one held, any kept beside it, the merge, and the next revision.
public struct DeviceRemovalCatalogueBase: Sendable {
    public let held: Data?
    public let contested: [Data]
    public let merged: Catalogue
    let nextRevision: UInt64

    public init(held: Data?, contested: [Data], merged: Catalogue, nextRevision: UInt64) {
        self.held = held
        self.contested = contested
        self.merged = merged
        self.nextRevision = nextRevision
    }
}

/// A device removal signed and ready to commit: the lists as they were before it, and the next of each.
public struct SignedDeviceRemoval: Sendable {
    let removedIDs: Set<String>
    let preRemoval: Members
    let preMembersBytes: Data?
    public let next: Members
    public let signedMembersBytes: Data
    public let base: DeviceRemovalCatalogueBase
    let nextCatalogue: Catalogue
    let signedCatalogueBytes: Data
}

extension SignedDeviceRemoval {
    /// iCloud's catalogue may go only if it is the one this removal started from, one kept beside it, or one
    /// of an earlier revision that gives way to the merge this removal signed.
    func mayReplaceCloudCatalogue(_ payload: Data, me: String, opener: CloudEnvelope.KeyOpener) -> Bool {
        guard let opened = CloudEnvelope.openCloudEnvelope(payload, expectedKind: CloudRecordKind.catalogue, deviceID: me, opener: opener) else {
            return false
        }
        let revision = Catalogue.trustedRevision(opened.plaintext, members: preRemoval)
        return revision == 0 || opened.plaintext == base.held || base.contested.contains(opened.plaintext)
            || (revision < base.merged.revision
                && CloudCatalogue.givesWay(opened.plaintext, to: nextCatalogue, members: preRemoval))
    }
}

@MainActor
package protocol CloudDeviceRemovalHost: CloudReplicaHost {
    /// The catalogue as held now, once no change to it is under way.
    func removalCatalogueBase() async -> DeviceRemovalCatalogueBase
    /// The next Members, signed, when only computers leave it.
    func publishMembersRemovingComputers(_ next: Members, signed: Data) async throws
    /// A newer Members from iCloud, taken while the removal holds this device's Members.
    func receiveSignedMembersDuringRemoval(_ signed: Data) async -> PeerIntakeOutcome
    /// Holds a signed removal here: after iCloud took both records, or with no iCloud. False when, with no
    /// iCloud, Members changed here since the removal was signed.
    func adoptDeviceRemoval(_ removal: SignedDeviceRemoval, committedInCloud: Bool) async throws -> Bool
}

extension CloudReplicaSyncCoordinator where Host: CloudDeviceRemovalHost {
    private enum DeviceRemovalAttempt { case finished, retry }

    /// Removes a device or computer, signing with this device's key (`sign`, under the user's confirmation).
    package func removeDeviceAtomically(_ id: String, signingWith sign: (Data) throws -> Data) async throws {
        guard let host, let me = host.replicaDeviceID else { return }
        for attempt in 0..<2 {
            // The list the removal starts from, as bytes and as checked, read together before anything waits.
            let preMembersBytes = host.replica.members
            guard let preRemoval = host.replica.currentMembers else { return }
            guard preRemoval.devices.contains(where: { $0.keyID == me }) else { throw CloudDeviceRemovalError.thisDeviceRemoved }
            let removed = CredentialSealing.pairedMac(id, in: preRemoval).union([id])
            var next = preRemoval
            next.domain = "agentkeyring.members.v2"
            next.revision = preRemoval.revision + 1
            next.machines.removeAll { removed.contains($0.machineID) }
            next.devices.removeAll { removed.contains($0.keyID) && $0.keyID != me }
            let removingDevice = next.devices.count != preRemoval.devices.count
            guard removingDevice || next.machines.count != preRemoval.machines.count else { return }
            let signedMembers = try CredentialSealing.signedDocument(next.serializedData(), by: me, sign: sign).serializedData()
            guard removingDevice else { return try await host.publishMembersRemovingComputers(next, signed: signedMembers) }
            let base = await host.removalCatalogueBase()
            var nextCatalogue = base.merged
            nextCatalogue.domain = "agentkeyring.catalogue.v2"
            nextCatalogue.revision = base.nextRevision
            let removal = SignedDeviceRemoval(
                removedIDs: removed, preRemoval: preRemoval, preMembersBytes: preMembersBytes, next: next,
                signedMembersBytes: signedMembers, base: base, nextCatalogue: nextCatalogue,
                signedCatalogueBytes: try CredentialSealing.signedDocument(nextCatalogue.serializedData(), by: me, sign: sign).serializedData()
            )
            // iCloud as it is now, never as the last pull found it: signed in again since, the removal must go there.
            let signedOut = await cloud?.availability() == .signedOut
            let outcome = if let cloud, !signedOut {
                try await commitRemovalInCloud(removal, cloud: cloud, me: me, attempt: attempt)
            } else {
                try await commitRemovalHere(removal, attempt: attempt)
            }
            switch outcome {
            case .finished: return
            case .retry: continue
            }
        }
    }

    /// Commits Members and the catalogue together in iCloud, each only over the revision this removal started from.
    private func commitRemovalInCloud(_ removal: SignedDeviceRemoval, cloud: any CloudPipe, me: String,
                                      attempt: Int) async throws -> DeviceRemovalAttempt {
        guard let host, await cloud.availability() == .available, let opener = host.replicaKeyOpener else {
            throw CloudDeviceRemovalError.cloudUnreachable
        }
        let history = host.replica.membersAncestry
        let membersRecord = CloudRecord(kind: CloudRecordKind.members, writer: me, payload: try CloudMembers.payload(
            current: removal.signedMembersBytes, history: host.replica.membersHistory))
        let catalogueRecord = CloudRecord(kind: CloudRecordKind.catalogue, writer: me, payload: try sealCache.sealForMembers(
            name: CloudRecordKind.catalogue, kind: CloudRecordKind.catalogue, plaintext: removal.signedCatalogueBytes,
            recipients: CloudEnvelope.recipients(for: removal.next), members: removal.next))
        let outcome = try await cloud.putMembersAndCatalogueAtomically(
            members: membersRecord,
            mayReplaceMembers: { CloudMembers.mayReplaceBase($0, base: removal.preMembersBytes, members: removal.preRemoval, history: history) },
            catalogue: catalogueRecord,
            mayReplaceCatalogue: { removal.mayReplaceCloudCatalogue($0, me: me, opener: opener) }
        )
        switch outcome {
        case .committed:
            _ = try await host.adoptDeviceRemoval(removal, committedInCloud: true)
            let current = host.replica.currentMembers
            let stillListed = current?.devices.contains { removal.removedIDs.contains($0.keyID) } == true
                || current?.machines.contains { removal.removedIDs.contains($0.machineID) } == true
            guard !stillListed else { throw CloudDeviceRemovalError.membersChangedFirst }
            host.replicaLog.noteDeviceEvent("catalogue", "resigned-after-removal", ["revision": "\(removal.nextCatalogue.revision)"])
            return .finished
        case let .membersConflict(theirs):
            await receiveCloudMembers(theirs, through: { await host.receiveSignedMembersDuringRemoval($0) })
            noteAnotherKeyring(theirs, members: removal.preRemoval, history: history)
            if attempt == 0, host.replica.currentMembers?.revision != removal.preRemoval.revision { return .retry }
            throw CloudDeviceRemovalError.membersChangedFirst
        case let .catalogueConflict(theirs):
            if attempt == 0,
               let opened = CloudEnvelope.openCloudEnvelope(theirs, expectedKind: CloudRecordKind.catalogue, deviceID: me, opener: opener),
               await host.receiveSignedCatalogue(opened.plaintext) == .taken { return .retry }
            throw CloudDeviceRemovalError.catalogueChangedFirst
        }
    }

    /// With no iCloud: holds the removal here, unless Members changed since it was signed.
    private func commitRemovalHere(_ removal: SignedDeviceRemoval, attempt: Int) async throws -> DeviceRemovalAttempt {
        guard let host else { return .finished }
        guard try await host.adoptDeviceRemoval(removal, committedInCloud: false) else {
            if attempt == 0 { return .retry }
            throw CloudDeviceRemovalError.membersChangedWhileRemoving
        }
        host.replicaLog.noteDeviceEvent("catalogue", "resigned-after-removal", ["revision": "\(removal.nextCatalogue.revision)"])
        return .finished
    }
}
