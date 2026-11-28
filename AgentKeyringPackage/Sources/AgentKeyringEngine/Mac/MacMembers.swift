// Written by AI on 2026.11.18 by model claude opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Changes this Mac signs with Touch ID: the members list (a rename, a removal)
// and the catalogue, each run one at a time against what this Mac and iCloud
// hold now.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
extension MacSyncCoordinator {
    // MARK: Signing, with Touch ID

    /// macOS's own dialog, with our sentence after "Agent Keyring is trying to".
    func confirm(_ context: LAContext, reason: String, until deadline: Date = .now.addingTimeInterval(600)) async throws {
        try await keys.confirmOwner(context, reason: reason, until: deadline)
        try Task.checkCancellation()
    }

    /// Runs `body` exclusively across local Members edits (`publishMembers`, `renameConfirmed`, `removeConfirmed`)
    /// so a concurrent rename or computer removal can never race with an atomic device removal.
    func withSerializedMembers<T: Sendable>(_ body: @MainActor @escaping () async throws -> T) async throws -> T {
        while let inFlight = membersOperation?.task {
            await inFlight.value
        }
        let runID = UUID()
        var outcome: Result<T, Error>?
        let task = Task { @MainActor in
            defer { if self.membersOperation?.id == runID { self.membersOperation = nil } }
            do { outcome = .success(try await body()) }
            catch { outcome = .failure(error) }
        }
        membersOperation = (runID, task)
        await task.value
        return try outcome!.get()
    }

    func publishMembersUnlocked(_ next: Agentkeyring_V2_Members, context: LAContext) async throws {
        var next = next
        next.domain = "agentkeyring.members.v2"
        next.revision = (members?.revision ?? 0) + 1
        let signed = try CredentialSealing.signedDocument(next.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: context) }
        guard await adoptMembers(next, signed: try signed.serializedData()) else { throw Self.membersNotSaved }
    }

    static let membersNotSaved = PeerIntakeFailure(description: "This Mac could not save the list of devices.")

    func publishMembers(_ next: Agentkeyring_V2_Members, context: LAContext) async throws {
        try await withSerializedMembers {
            try await self.publishMembersUnlocked(next, context: context)
        }
    }

    /// Runs `body` exclusively across local `publish(context:)`, incoming `receiveSignedCatalogue(_:)`, and imports,
    /// so publications never read half-applied rules, reuse a signed revision, or race with an import's copy retention.
    func withSerializedCatalogue<T: Sendable>(_ body: @MainActor @escaping () async throws -> T) async throws -> T {
        while let inFlight = catalogueOperation?.task {
            await inFlight.value
        }
        let runID = UUID()
        var outcome: Result<T, Error>?
        let task = Task { @MainActor in
            defer { if self.catalogueOperation?.id == runID { self.catalogueOperation = nil } }
            do { outcome = .success(try await body()) }
            catch { outcome = .failure(error) }
        }
        catalogueOperation = (runID, task)
        await task.value
        return try outcome!.get()
    }

    func withSerializedCatalogue<T: Sendable>(_ body: @MainActor @escaping () async -> T) async -> T {
        while let inFlight = catalogueOperation?.task {
            await inFlight.value
        }
        let runID = UUID()
        var outcome: T?
        let task = Task { @MainActor in
            defer { if self.catalogueOperation?.id == runID { self.catalogueOperation = nil } }
            outcome = await body()
        }
        catalogueOperation = (runID, task)
        await task.value
        return outcome!
    }

    /// Signs the catalogue with Touch ID: the devices and computers take its
    /// rules, and the copies of its versions, from the next bundle.
    /// Serialized with incoming catalogue adoption so publications never undo an iPhone rule change or reuse a revision.
    public func publish(context: LAContext) async throws {
        try await withSerializedCatalogue {
            guard self.members != nil else { return }
            var next = Agentkeyring_V2_Catalogue()
            next.domain = "agentkeyring.catalogue.v2"
            next.logins = try await self.catalogueLogins()
            // Allocate revision synchronously AFTER awaiting catalogueLogins so no concurrent
            // catalogue update can take the same revision number.
            next.revision = max(self.saved.catalogueRevision, self.catalogue?.revision ?? 0) + 1
            next.importedUnixSeconds = Int64(Date().timeIntervalSince1970)
            let signed = try CredentialSealing.signedDocument(next.serializedData(), by: self.keys.deviceKeyID) { try self.keys.signWithDeviceKey($0, context: context) }
            let signedBytes = try signed.serializedData()
            // Prune versions older than the signed catalogue, copies of a login
            // whose secret no device holds (version 0), and copies of logins it
            // no longer lists. Imports wait
            // for this, so it lists every login there is; an empty list prunes nothing unlisted.
            // Pruned before the catalogue is held, so a failed write leaves the changes and any contest unsent.
            let versions = Dictionary(next.logins.map { ($0.loginID, $0.version) }, uniquingKeysWith: { first, _ in first })
            let ownDeviceKeyID = self.keys.deviceKeyID
            let listsAll = !next.logins.isEmpty
            _ = try await self.store.updateSealed { sealed in
                sealed.filter { copy in
                    guard let published = versions[copy.loginID] else { return !listsAll && copy.openerID == ownDeviceKeyID }
                    return published != 0 && copy.version >= published
                }
            }
            self.saved.signCatalogue(signedBytes)
            self.saved.catalogueRevision = next.revision
            self.catalogue = next
            self.listsChanged(copies: true)
            KeyringDiagnosticLog.mac.noteDeviceEvent("catalogue", "signed", ["revision": "\(next.revision)", "passwords": "\(next.logins.count)"])
            await self.onPublished?()
        }
    }

    /// The model changed the copies held for these computers.
    func sendCopies(for machineIDs: Set<String>) {
        guard hasMembers, !machineIDs.isEmpty else { return }
        listsChanged(copies: true)
    }

    /// Removes a computer or another device, after Josh's Touch ID; the system dialog is the confirmation. The
    /// removal itself is the one every device makes (AgentKeyringEngine/Cloud/CloudDeviceRemoval.swift), one at a time
    /// with other changes to Members here.
    public func removeConfirmed(_ id: String, context: LAContext) async throws {
        guard let initial = members else { return }
        let label = initial.machines.first { $0.machineID == id }?.label ?? initial.devices.first { $0.keyID == id }?.label ?? "it"
        try await confirm(context, reason: MessageCopy.removeDeviceReason(label))
        await cloudSync.pullCloudNow()
        do {
            try await withSerializedMembers {
                try await self.cloudSync.removeDeviceAtomically(id) { try self.keys.signWithDeviceKey($0, context: context) }
            }
        } catch let failure as CloudDeviceRemovalError {
            throw AgentRPCError(failure == .thisDeviceRemoved ? .permissionDenied : .unavailable, Self.removalWords(failure))
        }
    }

    private static func removalWords(_ failure: CloudDeviceRemovalError) -> String {
        switch failure {
        case .thisDeviceRemoved: "This Mac was removed from the keyring."
        case .cloudUnreachable: "Couldn't confirm the latest lists in iCloud. Try again."
        case .membersChangedFirst: "Another device changed the list of devices first. Try removing again."
        case .catalogueChangedFirst: "Another device changed the password list first. Try removing again."
        case .membersChangedWhileRemoving: "The list of devices changed while removing. Try removing again."
        }
    }

    /// Renames a device or another computer in Members, after owner confirmation, so every device shows the new name.
    public func renameConfirmed(_ id: String, to newName: String, context: LAContext) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let initial = members else { return }
        let current = initial.machines.first { $0.machineID == id }?.label ?? initial.devices.first { $0.keyID == id }?.label ?? "it"
        guard trimmed != current else { return }
        try await confirm(context, reason: MessageCopy.renameDeviceReason(current, to: trimmed))
        // Re-read current Members inside the Members lock so a concurrent removal is never reversed.
        try await withSerializedMembers {
            guard var next = self.members else { return }
            if let idx = next.devices.firstIndex(where: { $0.keyID == id }) {
                next.devices[idx].label = trimmed
            } else if let idx = next.machines.firstIndex(where: { $0.machineID == id }) {
                next.machines[idx].label = trimmed
            } else {
                return
            }
            try await self.publishMembersUnlocked(next, context: context)
        }
    }

    /// A catalogue this Mac signed: held and served, with any contest over.
    func adoptSignedCatalogue(_ next: Agentkeyring_V2_Catalogue, signed: Data) {
        saved.signCatalogue(signed)
        saved.catalogueRevision = next.revision
        catalogue = next
    }

    /// The other openers each login must be sealed to: devices' opening keys,
    /// and every enrolled computer's receiving key for Automatic logins.
    func otherOpeners(automatic: Bool) -> [(id: String, key: P256.KeyAgreement.PublicKey)] {
        guard let members else { return [] }
        let devices = members.devices.filter { $0.keyID != keys.deviceKeyID }.compactMap { device in
            (try? P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)).map { (device.keyID, $0) }
        }
        guard automatic else { return devices }
        return devices + members.machines.filter { $0.machineID != keys.machineID }.compactMap { machine in
            (try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)).map { (machine.machineID, $0) }
        }
    }
}

@MainActor
extension MacSyncCoordinator: CloudDeviceRemovalHost {
    /// The catalogue as held, once no change to it is under way, with the next revision this Mac may sign.
    package func removalCatalogueBase() async -> DeviceRemovalCatalogueBase {
        await withSerializedCatalogue {
            let merged = self.catalogue ?? Agentkeyring_V2_Catalogue()
            return DeviceRemovalCatalogueBase(held: self.saved.catalogue, contested: self.saved.contestedCatalogues, merged: merged,
                                              nextRevision: max(self.saved.catalogueRevision, merged.revision) + 1)
        }
    }

    package func publishMembersRemovingComputers(_ next: Agentkeyring_V2_Members, signed: Data) async throws {
        guard await adoptMembers(next, signed: signed) else { throw Self.membersNotSaved }
    }

    /// Holds the removal unless a newer revision landed meanwhile: after iCloud took both records, the Members
    /// and catalogue it accepted are noted either way.
    package func adoptDeviceRemoval(_ removal: SignedDeviceRemoval, committedInCloud: Bool) async throws -> Bool {
        let adopted: Bool = try await withSerializedCatalogue {
            guard committedInCloud || self.saved.members == removal.preMembersBytes else { return false }
            let (savedBefore, catalogueBefore) = (self.saved, self.catalogue)
            let notSaved = {
                self.saved = savedBefore
                self.catalogue = catalogueBefore
                return Self.membersNotSaved
            }
            if committedInCloud { self.saved.cloudAcceptedCatalogue = removal.signedCatalogueBytes }
            if self.saved.catalogue == removal.base.held {
                self.adoptSignedCatalogue(removal.nextCatalogue, signed: removal.signedCatalogueBytes)
            }
            // Members inside the lock, so no incoming revision lands between the check and adoption.
            if committedInCloud { self.saved.cloudAcceptedMembers = removal.signedMembersBytes }
            guard self.saved.members == removal.preMembersBytes else {
                guard self.persist() else { throw notSaved() }
                self.cloudSync.pushCloudSoon()
                return true
            }
            guard await self.adoptMembers(removal.next, signed: removal.signedMembersBytes) else { throw notSaved() }
            return true
        }
        return adopted
    }
}
#endif
