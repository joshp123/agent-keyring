// Written by AI on 2026.11.24 by model claude opus 5.5.
//
// Apple Watch's own copies, which this iPhone keeps on it (keyring.proto,
// WatchCopies): every copy sealed to the Watch, by this iPhone or by the Mac
// (from iCloud), of the versions the signed Catalogue lists, sent as one
// generation whenever that set changes: an import here or on the Mac, a rule
// changed, a password Blocked. The Watch replaces what it held with each
// generation and says which it holds. No computer or relay ever carries them.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

extension PhoneKeyringEngine {
    /// The listed Apple Watch, if any.
    var listedWatch: Agentkeyring_V2_Device? { members?.devices.first { $0.kind == .watch } }

    /// Every copy the Watch should hold now: this iPhone's and the Mac's, the newest of each password.
    var copiesForWatch: [SealedLogin] {
        guard let watch = listedWatch else { return [] }
        let fromOthers = state.watchCopiesFromOthers.flatMap { try? Agentkeyring_V2_SealedLogins(serializedBytes: $0) }?.logins ?? []
        var newest: [String: SealedLogin] = [:]
        for copy in Self.current(madeForOthers + fromOthers, catalogue: catalogue, members: members) where copy.openerID == watch.keyID {
            if let members, let login = catalogue?.logins.first(where: { $0.loginID == copy.loginID }),
               (try? CredentialSealing.verifySealedLogin(copy, members: members, listed: login)) == nil { continue }
            if newest[copy.loginID] == nil { newest[copy.loginID] = copy }
        }
        return newest.values.sorted { $0.loginID < $1.loginID }
    }

    /// True when `copiesForWatch` already holds a current copy for every eligible login in the Catalogue.
    private var watchCopiesCoverAllEligible: Bool {
        let eligible = Set((catalogue?.logins ?? []).filter(\.holdsSecret).map(\.loginID))
        let covered = Set(copiesForWatch.map(\.loginID))
        return eligible.isSubset(of: covered)
    }

    /// The Watch's copies changed: a new generation goes to it a moment later, once.
    func syncWatchCopiesSoon() {
        guard listedWatch != nil else { return }
        if state.watchCopiesPending != nil, !watchCopiesCoverAllEligible { return }
        watchCopiesSyncing?.cancel()
        watchCopiesSyncing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.sendWatchCopies()
        }
    }

    /// Sends the Watch its copies as the next generation; returns that generation.
    @discardableResult
    func sendWatchCopies() -> UInt64? {
        guard let watch = listedWatch ?? pendingWatch, let send = onWatchCopies else { return nil }
        var batch = Agentkeyring_V2_WatchCopies()
        // Past what the Watch holds too: an iPhone set up again starts its count afresh, and the Watch takes only newer.
        batch.generation = max(state.watchCopiesSent ?? 0, state.watchCopiesHeld ?? 0) + 1
        batch.copies = copiesForWatch.filter { $0.openerID == watch.keyID }
        batch.catalogueRevision = catalogue?.revision ?? 0
        // An empty generation only when no password is held: a Watch added in 1.0 has no copies sealed for it
        // yet, and would take an empty one as its whole list. They are sealed at the next Face ID here.
        if batch.copies.isEmpty, catalogue?.logins.contains(where: \.holdsSecret) == true {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "copies not sent", ["reason": "none sealed for it yet"])
            return nil
        }
        guard let bytes = try? batch.serializedData() else { return nil }
        var next = state
        next.watchCopiesSent = batch.generation
        save(next)
        send(bytes, batch.generation)
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "copies sent", ["generation": "\(batch.generation)", "count": "\(batch.copies.count)"])
        return batch.generation
    }

    /// Sends the Watch its copies and waits, up to two minutes, for it to say it holds that exact generation.
    /// If the Watch reports a higher generation floor (`held > generation`), immediately resends once at `held + 1`.
    func sendWatchCopiesAndWait() async throws -> Bool {
        guard var generation = sendWatchCopies() else { return false }
        let deadline = Date().addingTimeInterval(120)
        var resentForFloor = false
        while Date() < deadline {
            if let held = state.watchCopiesHeld {
                if held == generation { return true }
                if held > generation, !resentForFloor {
                    resentForFloor = true
                    guard let nextGeneration = sendWatchCopies() else { return false }
                    generation = nextGeneration
                    continue
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// The Watch says which generation of its copies it holds. One that holds none, or less than was sent
    /// (a Watch set up again, a file lost, or a Watch added before it kept its own), is sent the current one.
    /// Clears `watchCopiesPending` once the Watch acknowledges the sent generation.
    public func watchHolds(copiesGeneration: UInt64) {
        let changed = copiesGeneration != state.watchCopiesHeld
        let sent = state.watchCopiesSent ?? 0
        var clearedPending = false
        if changed || (state.watchCopiesPending != nil && sent > 0 && copiesGeneration == sent && watchEnrollment.encryptionTask == nil) {
            var next = state
            next.watchCopiesHeld = copiesGeneration
            if let pending = next.watchCopiesPending,
               sent > 0,
               copiesGeneration == sent,
               listedWatch?.keyID == pending,
               watchEnrollment.encryptionTask == nil,
               watchCopiesCoverAllEligible {
                next.watchCopiesPending = nil
                clearedPending = true
            }
            if changed || clearedPending {
                save(next)
                if changed {
                    KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "copies held", ["generation": "\(copiesGeneration)"])
                }
            }
        }
        if clearedPending {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "copies pending cleared", ["generation": "\(copiesGeneration)"])
            if watchEnrollment.isEnrolledDeliveryPending && watchEnrollment.encryptionTask == nil {
                finishWatchEnrollment()
            } else {
                onListsChanged?()
            }
        }
        if (copiesGeneration == 0 || (sent > 0 && copiesGeneration != sent)), watchEnrollment.encryptionTask == nil {
            syncWatchCopiesSoon()
        }
    }

    /// On coming to the front: a listed Watch that was never sent a generation is sent one, and the copies the
    /// Mac sealed for it before this iPhone kept them (records iCloud already gave and this iPhone passed over)
    /// are read once more, in full.
    func catchUpWatchCopies() {
        guard listedWatch != nil else { return }
        if state.watchCopiesFromOthers == nil {
            var next = state
            next.watchCopiesFromOthers = Data()
            save(next)
            cloudSync.readWholeCloudNext()
        }
        if state.watchCopiesSent == nil || (state.watchCopiesPending != nil && watchCopiesCoverAllEligible) {
            syncWatchCopiesSoon()
        }
    }

    /// With a Face ID just given for something else: every password this iPhone holds that the listed Watch
    /// has no copy of (a Watch added in 1.0 has none) is sealed for it, and goes as the next generation.
    func sealMissingWatchCopies(context: LAContext) async {
        guard let watch = listedWatch, watchEnrollment.encryptionTask == nil, let members, let catalogue,
              let watchKey = try? P256.KeyAgreement.PublicKey(x963Representation: watch.openingPublicKey) else { return }
        let held = Set(copiesForWatch.map(\.loginID))
        let own = ownCopies
        let missing = catalogue.logins.filter { $0.holdsSecret && !held.contains($0.loginID) }.compactMap { login -> SealedLogin? in
            guard let copy = own[login.loginID], (try? CredentialSealing.verifySealedLogin(copy, members: members, listed: login)) != nil else { return nil }
            return copy
        }
        guard !missing.isEmpty else { return }
        do {
            let open = try keys.opener(context: context)
            let sign = try keys.replySigner()
            let replyKeyID = CredentialSealing.keyID(try keys.replyPublicKey())
            let watchID = watch.keyID
            let sealed = try await Task.detached {
                let signer = PayloadReplySigner(keyID: replyKeyID, sign: sign)
                return try missing.map { try CredentialSealing.sealLogin(open($0), version: $0.version, to: watchKey, openerID: watchID, signer: signer) }
            }.value
            guard listedWatch?.keyID == watchID else { return }
            keepMadeForOthers(sealed)
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "missing copies sealed", ["count": "\(sealed.count)"])
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "missing copies not sealed", ["error": "\(error)"])
        }
    }

    /// Copies another device (the Mac) sealed for the listed Watch, from iCloud, already checked: kept to pass on.
    /// False when they were not saved.
    func keepWatchCopiesFromOthers(_ fresh: [SealedLogin]) -> Bool {
        guard let members, let catalogue else { return false }
        let held = state.watchCopiesFromOthers.flatMap { try? Agentkeyring_V2_SealedLogins(serializedBytes: $0) }?.logins ?? []
        let replaced = Set(fresh.map(\.loginID))
        var allLogins = Agentkeyring_V2_SealedLogins()
        allLogins.logins = Self.current(fresh + held.filter { !replaced.contains($0.loginID) }, catalogue: catalogue, members: members)
        var next = state
        next.watchCopiesFromOthers = try? allLogins.serializedData()
        guard save(next) else { return false }
        syncWatchCopiesSoon()
        return true
    }
}
