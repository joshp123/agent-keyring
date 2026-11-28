// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// The lists this iPhone keeps: Members and the catalogue each checked against the one before, and its own copy
// of every password the catalogue says a device holds.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

@MainActor
extension PhoneKeyringEngine {
    /// Fetches the lists and this iPhone's copies from iCloud. True if iCloud answered, or when this iPhone
    /// holds the lists itself.
    @discardableResult
    func refresh() async -> Bool {
        let fromCloud = await cloudSync.pullCloudNow()
        // Requests that arrived before the lists that name their computer: checked again now.
        if fromCloud, !unverifiedRequestEnvelopes.isEmpty {
            let queued = Array(unverifiedRequestEnvelopes.values)
            unverifiedRequestEnvelopes.removeAll()
            for work in queued { receive(work, allowRefresh: false) }
        }
        return fromCloud || state.deviceKeyID != nil
    }


    /// This iPhone's copies with these added: per password, the one of the catalogue's current version,
    /// a new one before one held. A copy of any other version, or of a password no device holds, goes.
    func keepOwnSealedCopies(_ fresh: [SealedLogin], against targetCatalogue: Catalogue? = nil) throws {
        guard let members, let activeCatalogue = targetCatalogue ?? catalogue else { return }
        let listed = Dictionary(activeCatalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [String: SealedLogin] = [:]
        for copy in fresh + Array(ownCopies.values) where kept[copy.loginID] == nil {
            guard let login = listed[copy.loginID], login.holdsSecret,
                  (try? CredentialSealing.verifySealedLogin(copy, members: members, listed: login)) != nil else { continue }
            kept[copy.loginID] = copy
        }
        var copies = Agentkeyring_V2_SealedLogins()
        copies.logins = kept.values.sorted { $0.loginID < $1.loginID }
        var next = state
        next.copies = try copies.serializedData()
        guard save(next) else { throw CocoaError(.fileWriteUnknown) }
        copiesHeld = copies.logins.count
        copiesExpected = activeCatalogue.logins.filter(\.holdsSecret).count
    }


    var ownCopies: [String: SealedLogin] {
        let held = state.copies.flatMap { try? Agentkeyring_V2_SealedLogins(serializedBytes: $0) }?.logins ?? []
        return Dictionary(held.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A newer members list, checked against the one held. One that leaves this iPhone out resets it.
    @discardableResult
    package func receiveSignedMembers(_ bytes: Data) -> PeerIntakeOutcome {
        let signed: SignedDocument
        let verified: Members
        do {
            signed = try SignedDocument(serializedBytes: bytes)
            if let current = state.members, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return .taken }
            verified = try CredentialSealing.verifySignedMembers(signed, current: members)
        } catch {
            return .refused("This members list was refused: \(error).")
        }
        guard verified.devices.contains(where: { $0.keyID == state.deviceKeyID }) else {
            // This iPhone was removed: forget everything it held, stop active flows/timers, and look for a Mac again.
            guard save(PhoneSavedState()) else { return .notSaved("The reset after removal was not saved.") }
            clearRuntimeState()
            cloudSync.cloud?.forgetLocalCloudState()
            shared.deleteSharedContext()
            recordWatchReset()
            onListsChanged?()
            apply(.removed)
            return .taken
        }
        var next = state
        // Every revision since joining is kept, to send with answers in a box.
        next.adoptMembers(verified, signed: bytes)
        if let made = try? Agentkeyring_V2_SealedLogins(serializedBytes: next.sealedForOthers ?? Data()) {
            var kept = made
            kept.logins = Self.current(made.logins, catalogue: catalogue, members: verified)
            if kept.logins.count != made.logins.count {
                next.sealedForOthers = try? kept.serializedData()
            }
        }
        let previousWatchID = members?.devices.first(where: { $0.kind == .watch })?.keyID
        let currentWatchID = verified.devices.first(where: { $0.kind == .watch })?.keyID
        if let previousWatchID, previousWatchID != currentWatchID {
            next.watchCopiesPending = nil
            next.watchCopiesSent = nil
            next.watchCopiesHeld = nil
            next.watchCopiesFromOthers = nil
            next.watchDevice = nil
            next.watchPush = nil
            next.watchSelfTest = nil
            if watchEnrollment.committedWatchKeyID == previousWatchID {
                watchEnrollment.hold?.invalidate()
                watchEnrollment = .none
            }
        } else if let pending = next.watchCopiesPending, !verified.devices.contains(where: { $0.kind == .watch && $0.keyID == pending }) {
            next.watchCopiesPending = nil
            if watchEnrollment.committedWatchKeyID == pending {
                watchEnrollment.hold?.invalidate()
                watchEnrollment = .none
            }
        }
        if let pendingComputer = next.pendingComputerDelivery,
           !verified.machines.contains(where: { $0.machineID == pendingComputer.machineID }) {
            next.pendingComputerDelivery = nil
            if case .deliveryFailed? = addComputerFlow {
                addComputerFlow = nil
            }
        }
        guard save(next) else { return .notSaved("The members list was not saved.") }
        onListsChanged?()
        cloudSync.mailboxes.writeMailboxSlotsSoon()
        syncWatchCopiesSoon()
        sortUnlistedPhoneLoginsIfNeeded()
        return .taken
    }

    /// A catalogue signed here or by another device. A later one is held; one signed apart is kept beside the
    /// held one and merged.
    @discardableResult
    package func receiveSignedCatalogue(_ bytes: Data) -> PeerIntakeOutcome {
        guard let members else { return .refused("A catalogue comes after the list of devices.") }
        var next = state
        let intake: CatalogueIntake
        do {
            let signed = try SignedDocument(serializedBytes: bytes)
            if let current = state.catalogue, let saved = try? SignedDocument(serializedBytes: current), saved.payload == signed.payload { return .taken }
            intake = try next.intakeCatalogue(bytes, members: members)
        } catch {
            return .refused("This catalogue was refused: \(error).")
        }
        guard intake == .newer || intake == .contested, let verified = next.effectiveCatalogue else {
            return .refused("This catalogue was refused: it is not newer than the one held.")
        }
        if intake == .contested {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("cloud", "catalogue contested", ["revision": "\(verified.revision)"])
        }
        // A password Blocked, deleted when it was, or gone: this iPhone's copy goes too.
        let holding = Set(verified.logins.filter(\.holdsSecret).map(\.loginID))
        var keptCount = copiesHeld
        if let held = try? Agentkeyring_V2_SealedLogins(serializedBytes: next.copies ?? Data()), held.logins.contains(where: { !holding.contains($0.loginID) }) {
            var kept = held
            kept.logins.removeAll { !holding.contains($0.loginID) }
            guard let bytes = try? kept.serializedData() else { return .notSaved("This iPhone's copies could not be written.") }
            next.copies = bytes
            keptCount = kept.logins.count
        }
        // Copies made here for others: a password Blocked or gone goes, and a computer's goes once it is no
        // longer Automatic. iCloud drops them a moment later.
        var dropped = false
        if let made = try? Agentkeyring_V2_SealedLogins(serializedBytes: next.sealedForOthers ?? Data()) {
            var kept = made
            kept.logins = Self.current(made.logins, catalogue: verified, members: members)
            if kept.logins.count != made.logins.count, let bytes = try? kept.serializedData() {
                next.sealedForOthers = bytes
                dropped = true
            }
        }
        guard save(next) else { return .notSaved("The catalogue was not saved.") }
        let countsChanged = copiesHeld != keptCount || copiesExpected != holding.count
        copiesHeld = keptCount
        copiesExpected = holding.count
        if countsChanged { publish() }
        if dropped || intake == .contested { cloudSync.pushCloudSoon() }
        onListsChanged?()
        cloudSync.mailboxes.writeMailboxSlotsSoon()
        syncWatchCopiesSoon()
        sortUnlistedPhoneLoginsIfNeeded()
        return .taken
    }

    var members: Members? { state.currentMembers }

    /// The signed catalogue, merged with any kept beside it while contested: what this iPhone enforces and
    /// signs its next one from.
    var catalogue: Catalogue? { state.effectiveCatalogue }
}
