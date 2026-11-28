// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Adding Apple Watch once it asks: listed in Members, a copy of every password sealed to it, and sent.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
extension PhoneKeyringEngine {
    /// With the held confirmation: lists Apple Watch, encrypts a copy of every eligible password for it,
    /// and sends them to the Watch. Refuses to acknowledge an incomplete batch when this iPhone does not yet
    /// hold current copies for every non-Blocked login in the Catalogue.
    func addWatchNow() {
        guard watchEnrollment.encryptionTask == nil else { return }
        guard let (flow, hold, initialWatchKeyID) = heldWatchConfirmation() else {
            return applyAddWatch(.confirmationLapsed)
        }
        guard hold.until > Date() else { return applyAddWatch(.confirmationLapsed) }
        addingWatchGeneration &+= 1
        let generation = addingWatchGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.parkUploadingWatchEnrollment(generation: generation) }
            await self.copyPasswordsToWatch(generation: generation, hold: hold, initialWatchKeyID: initialWatchKeyID)
        }
        watchEnrollment = .encrypting(flow: flow, hold: hold, task: task, generation: generation, watchKeyID: initialWatchKeyID)
    }

    /// The flow and Face ID hold that may start adding Apple Watch, and the Watch already listed, if any.
    private func heldWatchConfirmation() -> (PhoneAddWatch, WatchHold, String?)? {
        switch watchEnrollment {
        case let .holding(flow, hold): (flow, hold, nil)
        case let .enrolledDeliveryPending(flow?, watchKeyID, hold?): (flow, hold, watchKeyID)
        case .none, .idle, .authorizing, .encrypting, .enrolledDeliveryPending, .uploading: nil
        }
    }

    private func isCurrentWatchEnrollment(_ generation: UInt64) -> Bool {
        !Task.isCancelled && watchEnrollment.generation == generation
    }

    /// When the copying task ends while still uploading, it waits for delivery, keeping the hold only while it lasts.
    private func parkUploadingWatchEnrollment(generation: UInt64) {
        guard watchEnrollment.generation == generation,
              case let .uploading(flow, _, watchKeyID, activeHold, _, _) = watchEnrollment else { return }
        if let activeHold, activeHold.until > Date() {
            watchEnrollment = .enrolledDeliveryPending(flow: flow, watchKeyID: watchKeyID, hold: activeHold)
        } else {
            activeHold?.invalidate()
            watchEnrollment = .enrolledDeliveryPending(flow: flow, watchKeyID: watchKeyID, hold: nil)
        }
    }

    private func copyPasswordsToWatch(generation: UInt64, hold: WatchHold, initialWatchKeyID: String?) async {
        guard isCurrentWatchEnrollment(generation) else { return }
        let initialTotal = catalogue?.logins.filter(\.holdsSecret).count ?? ownCopies.count
        applyAddWatch(.watchAsked(total: initialTotal))
        do {
            // Always refresh before sealing so logins newly added on another device are never missed.
            guard await refresh() else {
                throw PhoneApprovalError.notAllowed("Could not refresh the catalogue.")
            }
            guard isCurrentWatchEnrollment(generation) else { return }
            guard let members, let catalogue else { throw PhoneApprovalError.notJoined }
            let eligible = catalogue.logins.filter(\.holdsSecret)
            let verifiedCopies = try verifiedCopiesForWatch(eligible, members: members)
            guard let watch = try await listWatchForCopies(
                members: members, initialWatchKeyID: initialWatchKeyID, hold: hold, generation: generation
            ) else { return }
            guard let forWatch = try await sealCopiesForWatch(
                verifiedCopies, to: watch, hold: hold, generation: generation
            ) else { return }
            guard forWatch.logins.count == eligible.count else {
                throw PhoneApprovalError.notAllowed("Incomplete Watch password batch.")
            }
            // Once the final copies leave the phone, keep uploading alive until the Watch says it
            // holds them, so neither Watch Cancel nor sheet close can discard them half-sent.
            if case let .encrypting(currentFlow, currentHold, currentTask, _, _) = watchEnrollment {
                watchEnrollment = .uploading(
                    flow: currentFlow,
                    offerID: currentHold.offerID,
                    watchKeyID: watch.keyID,
                    hold: currentHold,
                    task: currentTask,
                    generation: generation
                )
            }
            // Kept here for every later generation; sent to Apple Watch itself, never to a computer or the relay.
            keepMadeForOthers(forWatch.logins)
            guard try await sendWatchCopiesAndWait() else { throw PhoneApprovalError.notAllowed("Apple Watch did not say it holds them.") }
            guard isCurrentWatchEnrollment(generation) else { return }
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("addwatch", "copies on the Watch", ["count": "\(forWatch.logins.count)"])
            finishWatchEnrollment()
        } catch {
            guard isCurrentWatchEnrollment(generation) else { return }
            recoverFromWatchCopiesFailure(error)
        }
    }

    /// This iPhone's current copy of every eligible login, each checked against the signed lists.
    private func verifiedCopiesForWatch(_ eligible: [Agentkeyring_V2_Login], members: Agentkeyring_V2_Members) throws -> [SealedLogin] {
        let copies = ownCopies
        var verifiedCopies: [SealedLogin] = []
        verifiedCopies.reserveCapacity(eligible.count)
        for login in eligible {
            guard let copy = copies[login.loginID], copy.version == login.version else {
                throw PhoneApprovalError.passwordsMissing
            }
            try CredentialSealing.verifySealedLogin(copy, members: members, listed: login)
            verifiedCopies.append(copy)
        }
        return verifiedCopies
    }

    /// The Watch to seal for: already in Members, or listed there now and shared. Nil when superseded.
    private func listWatchForCopies(
        members: Agentkeyring_V2_Members, initialWatchKeyID: String?, hold: WatchHold, generation: UInt64
    ) async throws -> Agentkeyring_V2_Device? {
        let watch: Agentkeyring_V2_Device
        if let listed = members.devices.first(where: { $0.kind == .watch && ($0.keyID == initialWatchKeyID || $0.keyID == pendingWatch?.keyID) }) {
            watch = listed
            if state.watchCopiesPending != watch.keyID {
                var mark = state
                mark.watchCopiesPending = watch.keyID
                save(mark)
            }
        } else if let pending = pendingWatch {
            watch = pending
            try await shareMembersListingWatch(pending, members: members, hold: hold)
            guard isCurrentWatchEnrollment(generation) else { return nil }
        } else { throw PhoneApprovalError.notAllowed("Apple Watch has not asked.") }
        if case let .encrypting(currentFlow, currentHold, currentTask, currentGen, _) = watchEnrollment {
            watchEnrollment = .encrypting(
                flow: currentFlow,
                hold: currentHold,
                task: currentTask,
                generation: currentGen,
                watchKeyID: watch.keyID
            )
        }
        return watch
    }

    /// Adds the Watch to Members, signs and shares them; the pending mark is rolled back if sharing fails.
    private func shareMembersListingWatch(_ watch: Agentkeyring_V2_Device, members: Agentkeyring_V2_Members, hold: WatchHold) async throws {
        var members = members
        var mark = state
        mark.watchCopiesPending = watch.keyID
        save(mark)
        members.revision += 1
        members.devices.append(watch)
        let signed = try CredentialSealing.signedDocument(members.serializedData(), by: CredentialSealing.keyID(keys.signingPublicKey())) {
            try self.keys.signWithDeviceKey($0, context: hold.context)
        }
        do {
            try await share(members: signed)
        } catch {
            if self.members?.devices.contains(where: { $0.kind == .watch && $0.keyID == watch.keyID }) != true,
               state.watchCopiesPending == watch.keyID {
                var rollback = state
                rollback.watchCopiesPending = nil
                save(rollback)
            }
            throw error
        }
    }

    /// Opened and sealed again away from the main thread, with both keys loaded once, 50 at a time
    /// so the sheet can count. Nil when superseded.
    private func sealCopiesForWatch(
        _ verifiedCopies: [SealedLogin], to watch: Agentkeyring_V2_Device, hold: WatchHold, generation: UInt64
    ) async throws -> Agentkeyring_V2_SealedLogins? {
        let watchKey = try P256.KeyAgreement.PublicKey(x963Representation: watch.openingPublicKey)
        var forWatch = Agentkeyring_V2_SealedLogins()
        let total = verifiedCopies.count
        let open = try keys.opener(context: hold.context)
        let sign = try keys.replySigner()
        let replyKeyID = CredentialSealing.keyID(try keys.replyPublicKey())
        let watchID = watch.keyID
        for start in stride(from: 0, to: total, by: 50) {
            guard isCurrentWatchEnrollment(generation) else { return nil }
            let batch = Array(verifiedCopies[start..<min(start + 50, total)])
            forWatch.logins += try await Task.detached {
                let signer = PayloadReplySigner(keyID: replyKeyID, sign: sign)
                return try batch.map { try CredentialSealing.sealLogin(open($0), version: $0.version, to: watchKey, openerID: watchID, signer: signer) }
            }.value
            applyAddWatch(.encrypted(done: forWatch.logins.count, total: total))
        }
        guard isCurrentWatchEnrollment(generation) else { return nil }
        return forWatch
    }

    /// After copying failed: a Watch already listed waits for delivery, otherwise the hold is kept while it lasts.
    private func recoverFromWatchCopiesFailure(_ error: Error) {
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("addwatch", "copies failed", ["error": "\(error)"])
        let missing = (error as? PhoneApprovalError) == .passwordsMissing
        let committedID = watchEnrollment.committedWatchKeyID ?? (watchCopiesPending ? listedWatch?.keyID : nil)
        let currentFlow = watchEnrollment.flow
        let currentHold = watchEnrollment.hold
        if let committedID {
            if let currentHold, currentHold.until > Date() {
                watchEnrollment = .enrolledDeliveryPending(flow: currentFlow, watchKeyID: committedID, hold: currentHold)
            } else {
                currentHold?.invalidate()
                watchEnrollment = .enrolledDeliveryPending(flow: currentFlow, watchKeyID: committedID, hold: nil)
            }
        } else if let currentHold, currentHold.until > Date() {
            watchEnrollment = .holding(flow: currentFlow ?? .faceIDExpired, hold: currentHold)
        } else {
            currentHold?.invalidate()
            watchEnrollment = currentFlow.map(WatchEnrollment.idle) ?? .none
        }
        if watchEnrollment.flow != nil {
            applyAddWatch(.copiesFailed(reason: missing ? PhoneCopy.passwordsNotHereYet : PhoneCopy.watchNotReached))
        }
        // Always broadcast copyingToWatch = false even if the sheet closed or Face ID expired while uploading.
        onListsChanged?()
        publish()
    }

    func finishWatchEnrollment() {
        watchEnrollment.hold?.invalidate()
        var done = state
        done.watchDevice = nil
        done.watchCopiesPending = nil
        save(done)
        if watchEnrollment.flow != nil {
            applyAddWatch(.copiesSent)
        } else {
            watchEnrollment = .none
        }
        onListsChanged?()
        publish()
        if let rawPush = state.watchPush, let push = try? Agentkeyring_V2_PushRegistration(serializedBytes: rawPush) {
            Task { [weak self] in await self?.registerWatchPush(push, raw: rawPush) }
        }
    }

    var pendingWatch: Agentkeyring_V2_Device? {
        state.watchDevice.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
            ?? members?.devices.first { $0.kind == .watch }
    }

    /// The signed lists, for Apple Watch.
    public var signedMembers: Data? { state.members }
    public var signedCatalogue: Data? { state.catalogue }
}
