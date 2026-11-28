// Written by AI on 2026.11.27 by model GPT-6.2 Sol.

import AgentKeyringProtocol
import Foundation
#if os(watchOS)
import CryptoKit
#endif

/// Applies the phone's Watch state and prepares the replies. The caller serializes
/// operations on its I/O queue and delivers messages, timers and UI updates.
public struct WatchStateCoordinator: Sendable {
    private static func notificationSettings(from proto: Agentkeyring_V2_WatchNotificationSettings) -> NotificationSettings {
        var settings = NotificationSettings()
        settings.timeSensitive = proto.timeSensitive
        settings.quietHours = proto.quietHours
        settings.quietFrom = Int(proto.quietFromMinutes)
        settings.quietTo = Int(proto.quietToMinutes)
        return settings
    }

    /// The reset generation orders all deliveries. Within a generation, signed lists
    /// advance by revision and control fields follow the latest context timestamp.
    static func merge(_ message: Agentkeyring_V2_PhoneToWatch, into saved: WatchPersistedState,
                      current: Bool, keyID: String, now: Date) -> (saved: WatchPersistedState, removed: Bool)? {
        let resetAt = message.resetAtUnixSeconds
        let heldResetAt = saved.lastResetAt ?? 0
        guard resetAt.isFinite, resetAt >= heldResetAt else { return nil }
        let reset = resetAt > heldResetAt
        let base = reset ? WatchPersistedState() : saved
        let applyControls = message.hasSentAtUnixSeconds
            ? message.sentAtUnixSeconds >= (base.lastContextSentAt ?? 0)
            : current && base.lastContextSentAt == nil
        let addUntil = message.hasAddUntilUnixSeconds ? Date(timeIntervalSince1970: message.addUntilUnixSeconds) : nil
        var next = base.merging(
            members: message.hasMembers ? message.members : nil,
            catalogue: message.hasCatalogue ? message.catalogue : nil,
            settings: applyControls && message.hasSettings ? notificationSettings(from: message.settings) : nil,
            addUntil: applyControls ? addUntil : base.addUntil,
            addOfferID: applyControls ? (message.hasAddOfferID ? message.addOfferID : nil) : base.addOfferID,
            copiesPending: applyControls && message.hasCopiesPending ? message.copiesPending : nil,
            copyingToWatch: applyControls && message.hasCopyingToWatch ? message.copyingToWatch : nil
        )
        if reset { next.lastResetAt = resetAt }
        if applyControls, message.hasSentAtUnixSeconds { next.lastContextSentAt = message.sentAtUnixSeconds }
        if applyControls, message.hasRelayURL { next.relayURL = message.relayURL.isEmpty ? nil : message.relayURL }

        let wasListed = !keyID.isEmpty && saved.lists(keyID)
        let nowListed = !keyID.isEmpty && next.lists(keyID)
        let unlisted = wasListed && !nowListed
        if nowListed {
            if next.copiesPending != true && next.copyingToWatch != true {
                next.addTappedOfferID = nil
            } else if next.copyingToWatch == true, let offer = next.effectiveAddOfferID {
                next.addTappedOfferID = offer
            }
        } else if unlisted {
            next.addTappedOfferID = nil
            next.copiesPending = nil
            next.copyingToWatch = nil
            next.practiceAnswered = nil
            next.practiceOfferDone = nil
            next.practiceAsked = nil
        } else if next.copyingToWatch != true,
                  (next.addUntil ?? .distantPast) <= now || next.effectiveAddOfferID != next.addTappedOfferID {
            next.addTappedOfferID = nil
        }
        return (next, reset || unlisted)
    }

    struct FileDelivery {
        let message: Agentkeyring_V2_PhoneToWatch
        let copies: Agentkeyring_V2_WatchCopies?

        init?(_ data: Data?, metadata: Agentkeyring_V2_WatchFileMetadata, resetAt: Double) {
            guard let data else { return nil }
            var message = Agentkeyring_V2_PhoneToWatch()
            message.resetAtUnixSeconds = resetAt
            if !metadata.members.isEmpty { message.members = metadata.members }
            switch metadata.kind {
            case .catalogue:
                message.catalogue = data
                copies = nil
            case .copies:
                guard let batch = try? Agentkeyring_V2_WatchCopies(serializedBytes: data) else { return nil }
                copies = batch
            case .unspecified, .UNRECOGNIZED:
                return nil
            }
            self.message = message
        }
    }

    /// A forced handover arriving during a send schedules one more pass.
    public struct HandOverSchedule: Sendable {
        private var inFlight = false
        private var pending = false
        private var lastSent: Date = .distantPast

        public init() {}

        public mutating func begin(force: Bool, now: Date = .now) -> Bool {
            if inFlight {
                pending = pending || force
                return false
            }
            guard force || now.timeIntervalSince(lastSent) >= 5 else { return false }
            inFlight = true
            return true
        }

        public mutating func finish(now: Date = .now) -> Bool {
            lastSent = now
            inFlight = pending
            pending = false
            return inFlight
        }
    }

    public static func practiceRequest() -> Agentkeyring_V2_WatchToPhone {
        var message = Agentkeyring_V2_WatchToPhone()
        message.requestPractice = true
        return message
    }

    public static func stopRequest(_ id: String) -> Agentkeyring_V2_WatchToPhone {
        var message = Agentkeyring_V2_WatchToPhone()
        message.stopRequestID = id
        return message
    }

    public static func dismissRequest(_ id: String) -> Agentkeyring_V2_WatchToPhone {
        var message = Agentkeyring_V2_WatchToPhone()
        message.dismissRequestID = id
        return message
    }

    public struct FileReceipt: Sendable {
        public let response: Agentkeyring_V2_WatchToPhone?
        public let refreshSetup: Bool
        public let handOver: Bool
        public let addUntil: Date?
        public let removed: Bool

        fileprivate init(response: Agentkeyring_V2_WatchToPhone? = nil, refreshSetup: Bool = false,
                         handOver: Bool = false, addUntil: Date? = nil, removed: Bool = false) {
            self.response = response
            self.refreshSetup = refreshSetup
            self.handOver = handOver
            self.addUntil = addUntil
            self.removed = removed
        }
    }

    #if os(watchOS)
    private let keys = WatchKeys()
    private let store = WatchKeychainStateStore()
    private let copies = WatchCopiesStore()
    private let log: KeyringDiagnosticLog

    public init(log: KeyringDiagnosticLog) {
        self.log = log
    }

    public func receive(_ message: Agentkeyring_V2_PhoneToWatch, current: Bool) -> (addUntil: Date?, removed: Bool) {
        guard let update = apply(message, current: current, keyID: (try? keys.keyID()) ?? "") else {
            return (nil, false)
        }
        return (update.saved.addUntil, update.removed)
    }

    private func apply(_ message: Agentkeyring_V2_PhoneToWatch, current: Bool, keyID: String)
        -> (saved: WatchPersistedState, removed: Bool)?
    {
        var removed: Bool?
        guard let saved = store.updateIfReadable({ saved in
            guard let update = Self.merge(message, into: saved, current: current, keyID: keyID, now: .now) else { return }
            saved = update.saved
            removed = update.removed
        }), let removed else { return nil }
        if removed {
            store.clearInUse()
            copies.deleteWatchCopies()
        }
        if message.hasCatalogue { copies.prune(catalogue: saved.signedCatalogue) }
        WatchRelayConfiguration.applyRelayOverride(saved)
        return (saved, removed)
    }

    /// Builds a typed `WatchToPhone` message including `copiesGeneration`, optional device identity, and push registration.
    private func buildWatchToPhone(
        includeDevice: Bool,
        offerID: String? = nil,
        pushToken: Data?
    ) throws -> Agentkeyring_V2_WatchToPhone {
        var message = acknowledgement()
        if includeDevice {
            message.watchDevice = try keys.device().serializedData()
            if let offerID { message.addOfferID = offerID }
        }
        if let token = pushToken {
            var push = Agentkeyring_V2_PushRegistration()
            push.deviceKeyID = try keys.keyID()
            push.apnsToken = token
            push.apnsTopic = Bundle.main.bundleIdentifier ?? ""
            push.apnsProduction = PushEnvironment.isProduction
            push.noticePublicKey = try keys.noticePublicKey()
            message.watchPush = try push.serializedData()
        }
        return message
    }

    public func handOver(selfTest: Agentkeyring_V2_WatchSelfTest, pushToken: Data?)
        -> (message: Agentkeyring_V2_WatchToPhone, keyError: String?)
    {
        log.collect()
        var message: Agentkeyring_V2_WatchToPhone
        var keyError: String?
        do {
            let saved = store.readWatchState()
            let keyID = try keys.keyID()
            let tappedOfferID = saved.addTappedOfferID
            let includeDevice = tappedOfferID != nil && tappedOfferID == saved.effectiveAddOfferID && !saved.lists(keyID)
            message = try buildWatchToPhone(includeDevice: includeDevice, offerID: tappedOfferID, pushToken: pushToken)
        } catch {
            message = acknowledgement()
            keyError = "The Watch could not make its keys: \(error)"
        }
        // Keep the WatchConnectivity application context below its size limit.
        message.logLines = log.lines(last: 60)
        message.selfTest = selfTest
        return (message, keyError)
    }

    public func selfTest(
        passcode: Bool, onWrist: Bool, notificationsAllowed: Bool, timeSensitiveAllowed: Bool,
        hasPushToken: Bool, problem: String?
    ) -> Agentkeyring_V2_WatchSelfTest {
        var result = Agentkeyring_V2_WatchSelfTest()
        result.atUnixSeconds = Int64(Date().timeIntervalSince1970)
        do {
            // A login sealed to this Watch's opening key, opened by its chip.
            var secret = LoginSecret()
            secret.loginID = "self-test"
            secret.password = "example"
            let openerID = try keys.keyID()
            let opening = try P256.KeyAgreement.PublicKey(x963Representation: keys.openingPublicKey())
            let sealed = try CredentialSealing.sealLogin(secret, version: 0, to: opening, openerID: openerID,
                                          signer: PayloadReplySigner(keyID: CredentialSealing.keyID(keys.replyPublicKey()), sign: keys.signReply))
            result.keyOpens = try keys.openSealedLogin(sealed).password == "example"
        } catch {
            result.keyOpens = false
            result.keyError = "\(error)"
        }
        result.passcodeSet = passcode
        result.onWristAndUnlocked = onWrist
        result.notificationsAllowed = notificationsAllowed
        result.timeSensitiveAllowed = timeSensitiveAllowed
        result.pushAddress = hasPushToken
        result.practiceAnswered = store.readWatchState().practiceAnswered == true
        if let problem { result.problem = problem }
        return result
    }

    public func makeSetup(saved: WatchPersistedState, notifications: WatchNotificationPermission, hasPushToken: Bool, passcode: Bool) -> WatchOnboardingStep {
        let listed = saved.lists((try? keys.keyID()) ?? "")
        let now = Date.now
        let addOffered = saved.addUntil.map { $0 > now } ?? false
        return WatchOnboardingStep(
            passcode: passcode,
            phoneJoined: saved.signedMembers != nil,
            listed: listed,
            addOffered: addOffered,
            addTapped: saved.isAddTappedForCurrentOffer,
            copiesPending: saved.copiesPending == true,
            copyingToWatch: saved.copyingToWatch == true,
            notifications: notifications,
            pushAddress: hasPushToken || saved.practiceOfferDone == true,
            practiceAsked: saved.practiceAnswered == true ? nil : saved.practiceAsked,
            practiceOfferDone: saved.practiceOfferDone == true,
            now: now
        )
    }

    public func setupSnapshot(notifications: WatchNotificationPermission, hasPushToken: Bool, passcode: Bool)
        -> (setup: WatchOnboardingStep, inUse: [WatchInUse])
    {
        (makeSetup(saved: store.readWatchState(), notifications: notifications, hasPushToken: hasPushToken, passcode: passcode),
         store.readInUse())
    }

    public func membersRequest() -> (saved: WatchPersistedState, request: Agentkeyring_V2_WatchToPhone) {
        let saved = store.readWatchState()
        var message = acknowledgement()
        message.askMembers = true
        message.needCatalogue = saved.catalogue == nil
        return (saved, message)
    }

    public func savedState() -> WatchPersistedState { store.readWatchState() }

    public func beginAdd() -> String? {
        guard let offerID = store.readWatchState().effectiveAddOfferID, !offerID.isEmpty else { return nil }
        store.update { $0.addTappedOfferID = offerID }
        return offerID
    }

    public func prepareAdd(offerID: String, pushToken: Data?) throws
        -> (context: Agentkeyring_V2_WatchToPhone, request: Agentkeyring_V2_WatchToPhone, keyID: String)
    {
        let needCatalogue = store.readWatchState().catalogue == nil
        let context = try buildWatchToPhone(includeDevice: true, offerID: offerID, pushToken: pushToken)
        var request = context
        request.addWatch = true
        request.needCatalogue = needCatalogue
        return (context, request, (try? keys.keyID()) ?? "")
    }

    public func isSendingAdd(offerID: String) -> Bool {
        let saved = store.readWatchState()
        return saved.addTappedOfferID == offerID && saved.effectiveAddOfferID == offerID
    }

    public enum AddProgress: Sendable { case waiting, accepted, cancelled }

    public func addProgress(offerID: String, keyID: String) -> AddProgress {
        let saved = store.readWatchState()
        if saved.copyingToWatch == true || (!keyID.isEmpty && saved.lists(keyID)) { return .accepted }
        return saved.addTappedOfferID == offerID ? .waiting : .cancelled
    }

    public func clearAdd(offerID: String) {
        store.update { if $0.addTappedOfferID == offerID { $0.addTappedOfferID = nil } }
    }

    public func cancelAdd() -> Agentkeyring_V2_WatchToPhone? {
        // Prefer the current offer, which may have changed after a Face ID retry.
        let before = store.readWatchState()
        store.update { $0.addTappedOfferID = nil }
        guard let offerID = before.addOfferID ?? before.addTappedOfferID, !offerID.isEmpty else { return nil }
        return cancelMessage(offerID: offerID)
    }

    public func cancelMessage(offerID: String) -> Agentkeyring_V2_WatchToPhone {
        var message = acknowledgement()
        message.cancelAddWatch = true
        message.addOfferID = offerID
        return message
    }

    public func practiceRequested() { store.update { $0.practiceAsked = .now } }
    public func cancelPractice() { store.update { $0.practiceAsked = nil } }
    public func practiceOfferDone() { store.update { $0.practiceOfferDone = true } }
    public func removeInUse(_ id: String) { store.removeInUse(id) }

    private func acknowledgement(generation: UInt64? = nil) -> Agentkeyring_V2_WatchToPhone {
        var message = Agentkeyring_V2_WatchToPhone()
        message.copiesGeneration = generation ?? copies.readWatchCopies().generation
        return message
    }

    public func receiveFile(_ data: Data?, metadata: Agentkeyring_V2_WatchFileMetadata, resetAt: Double) -> FileReceipt {
        guard let delivery = FileDelivery(data, metadata: metadata, resetAt: resetAt) else {
            log.noteDeviceEvent("transfer", "unreadable", ["kind": "\(metadata.kind)"])
            return FileReceipt()
        }
        let keyID = (try? keys.keyID()) ?? ""
        guard let update = apply(delivery.message, current: false, keyID: keyID) else { return FileReceipt() }
        if let batch = delivery.copies {
            return receiveCopies(batch, saved: update.saved, removed: update.removed, keyID: keyID)
        }
        log.noteDeviceEvent("catalogue", "received", ["bytes": "\(delivery.message.catalogue.count)"])
        return receiveCatalogue(saved: update.saved, removed: update.removed)
    }

    private func receiveCatalogue(saved: WatchPersistedState, removed: Bool) -> FileReceipt {
        guard let catalogue = saved.signedCatalogue,
              let generation = copies.applyPendingIfReady(catalogue: catalogue) else {
            return FileReceipt(refreshSetup: true, addUntil: saved.addUntil, removed: removed)
        }
        let held = copies.readWatchCopies()
        log.noteDeviceEvent("copies", "pending-applied", ["generation": "\(generation)", "count": "\(held.copies.count)"])
        return FileReceipt(response: acknowledgement(generation: held.generation), refreshSetup: true, handOver: true,
                           addUntil: saved.addUntil, removed: removed)
    }

    private func receiveCopies(_ batch: Agentkeyring_V2_WatchCopies, saved: WatchPersistedState, removed: Bool,
                               keyID: String) -> FileReceipt {
        guard !keyID.isEmpty, saved.lists(keyID) else {
            log.noteDeviceEvent("copies", "not listed", ["generation": "\(batch.generation)"])
            return FileReceipt(refreshSetup: removed, addUntil: saved.addUntil, removed: removed)
        }
        let result = copies.stageOrReplace(with: batch, catalogue: saved.signedCatalogue)
        let held = copies.readWatchCopies()
        var response = acknowledgement(generation: held.generation)
        let outcome: String
        switch result {
        case .applied: outcome = "taken"
        case .older: outcome = "older"
        case .writeFailed: outcome = "write-failed"
        case .stagedWaitingForCatalogue:
            log.noteDeviceEvent("copies", "staged-waiting-catalogue",
                     ["generation": "\(batch.generation)", "needRev": "\(batch.catalogueRevision)"])
            response.askMembers = true
            response.needCatalogue = true
            return FileReceipt(response: response, refreshSetup: removed, addUntil: saved.addUntil, removed: removed)
        }
        log.noteDeviceEvent("copies", outcome, ["generation": "\(batch.generation)", "count": "\(held.copies.count)"])
        return FileReceipt(response: response, refreshSetup: true, handOver: true,
                           addUntil: saved.addUntil, removed: removed)
    }
    #endif
}
