// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's side of Apple Watch. The iPhone sends the signed lists and
// settings whenever they change, and "addUntil" while it holds a Face ID
// confirmation for the Watch to be added: only then does the Watch offer Add.
// After Add, the Watch sends its Device and PushRegistration ("watchDevice",
// "watchPush"). Both directions use application context and user info, so it
// works whichever app opens first. The Watch's own copies of the passwords go
// as a file, one generation at a time ("copiesGeneration" says which it holds).

import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    nonisolated private static let pbKey = "pb"
    nonisolated private static let resetAtKey = "resetAtUnixSeconds"
    private let keyring: PhoneKeyringEngine
    private var lastSentCatalogue: (digest: Data, resetAt: Double)?

    init(keyring: PhoneKeyringEngine) {
        self.keyring = keyring
        super.init()
        keyring.onWatchMayAsk = { [weak self] in
            self?.sendMembers(immediate: true)
        }
        keyring.onListsChanged = { [weak self] in
            self?.sendMembers(immediate: true)
            self?.sendCatalogueIfNeeded()
        }
        keyring.onWatchCopies = { [weak self] bytes, generation in self?.sendCopies(bytes, generation: generation) }
        keyring.onRequestDismissed = { [weak self] id in self?.sendDismissRequest(id) }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Lightweight control context sent via applicationContext, sendMessage, and transferUserInfo
    /// (well under WatchConnectivity's 65 KB payload limit). The signed Catalogue travels via transferFile.
    private var membersMessage: Agentkeyring_V2_PhoneToWatch {
        var msg = Agentkeyring_V2_PhoneToWatch()
        if let members = keyring.signedMembers { msg.members = members }
        msg.settings = Self.protoSettings(keyring.notificationSettings)
        if let addUntil = keyring.watchAddUntil { msg.addUntilUnixSeconds = addUntil.timeIntervalSince1970 }
        if let offerID = keyring.activeWatchOfferID { msg.addOfferID = offerID }
        msg.copiesPending = keyring.watchCopiesPending
        msg.copyingToWatch = keyring.isCopyingToWatch
        msg.sentAtUnixSeconds = Date().timeIntervalSince1970
        let resetAt = keyring.watchResetAt
        if resetAt > 0 { msg.resetAtUnixSeconds = resetAt }
        let relay = RelayBoxClient.configured.url
        msg.relayURL = relay == RelayBoxProtocol.defaultURL ? "" : relay
        return msg
    }

    nonisolated private static func protoSettings(_ settings: NotificationSettings) -> Agentkeyring_V2_WatchNotificationSettings {
        var proto = Agentkeyring_V2_WatchNotificationSettings()
        proto.timeSensitive = settings.timeSensitive
        proto.quietHours = settings.quietHours
        proto.quietFromMinutes = Int32(settings.quietFrom)
        proto.quietToMinutes = Int32(settings.quietTo)
        return proto
    }

    nonisolated private static func encode(_ message: Agentkeyring_V2_PhoneToWatch) -> [String: Any] {
        guard let data = try? message.serializedData() else { return [:] }
        return [pbKey: data]
    }

    nonisolated private static func decode(_ payload: [String: Any]) -> Agentkeyring_V2_WatchToPhone? {
        guard let data = payload[pbKey] as? Data else { return nil }
        return try? Agentkeyring_V2_WatchToPhone(serializedBytes: data)
    }

    nonisolated private static func isControlContextTransfer(_ userInfo: [String: Any]) -> Bool {
        guard let data = userInfo[pbKey] as? Data,
              let msg = try? Agentkeyring_V2_PhoneToWatch(serializedBytes: data) else { return false }
        return msg.hasSentAtUnixSeconds
    }

    /// Sends the current lists, settings and Add offer to the Watch.
    /// Uses application context (latest-state replacement), a direct live message when reachable,
    /// and a single deduplicated userInfo transfer on urgent state changes so WatchConnectivity
    /// still delivers Face ID offers and copying progress when applicationContext is throttled.
    func sendMembers(immediate: Bool = false) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let message = membersMessage
        let payload = Self.encode(message)
        do { try session.updateApplicationContext(payload) } catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Lists not sent to the Watch: \(error)"]) }
        if immediate {
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil, errorHandler: Self.handleLiveMessageError)
            }
            for transfer in session.outstandingUserInfoTransfers where Self.isControlContextTransfer(transfer.userInfo) {
                transfer.cancel()
            }
            session.transferUserInfo(payload)
        }
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "lists sent", ["addOffered": "\(keyring.watchAddUntil != nil)", "reachable": "\(session.isReachable)"])
    }

    /// Tells Apple Watch immediately that a request was answered or ended on this iPhone so its alert clears at once.
    func sendDismissRequest(_ id: String) {
        let session = WCSession.default
        guard !id.isEmpty, WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        var msg = Agentkeyring_V2_PhoneToWatch()
        msg.dismissRequestID = id
        let payload = Self.encode(msg)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: Self.handleLiveMessageError)
        }
        session.transferUserInfo(payload)
    }

    /// `WCSession.sendMessage` invokes its error handler on WatchConnectivity's background queue,
    /// so it must be `nonisolated` rather than inheriting `@MainActor` from `WatchLink`.
    nonisolated private static func handleLiveMessageError(_ error: Error) {
        let description = "\(error)"
        Task { @MainActor in
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "live message failed", ["error": description])
        }
    }

    nonisolated private static func fileMetadata(from dictionary: [String: Any]?) -> Agentkeyring_V2_WatchFileMetadata? {
        guard let data = dictionary?[pbKey] as? Data else { return nil }
        return try? Agentkeyring_V2_WatchFileMetadata(serializedBytes: data)
    }

    /// Sends the signed Catalogue as a file transfer so large password catalogues (> 65 KB) never break
    /// WatchConnectivity's applicationContext or sendMessage payload limits.
    func sendCatalogueIfNeeded(force: Bool = false) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let catalogue = keyring.signedCatalogue else { return }
        let digest = Data(SHA256.hash(data: catalogue))
        let resetAt = keyring.watchResetAt
        let hasMatchingInFlight = session.outstandingFileTransfers.contains {
            guard let meta = Self.fileMetadata(from: $0.file.metadata) else { return false }
            let queuedResetAt = $0.file.metadata?[Self.resetAtKey] as? Double ?? 0
            return meta.kind == .catalogue && meta.digest == digest && queuedResetAt == resetAt
        }
        if hasMatchingInFlight { return }
        if !force, digest == lastSentCatalogue?.digest, resetAt == lastSentCatalogue?.resetAt { return }
        for transfer in session.outstandingFileTransfers where Self.fileMetadata(from: transfer.file.metadata)?.kind == .catalogue {
            transfer.cancel()
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "watch-catalogue-\(UUID().uuidString).pb")
        do {
            try catalogue.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var metadata = Agentkeyring_V2_WatchFileMetadata()
            metadata.kind = .catalogue
            metadata.digest = digest
            if let members = keyring.signedMembers { metadata.members = members }
            session.transferFile(file, metadata: [Self.pbKey: try metadata.serializedData(), Self.resetAtKey: resetAt])
            lastSentCatalogue = (digest, resetAt)
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "catalogue sent", ["bytes": "\(catalogue.count)"])
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Catalogue not sent to the Watch: \(error)"])
        }
    }

    /// Apple Watch's copies, one generation as one file: any older copies transfer still on its way is cancelled first.
    func sendCopies(_ bytes: Data, generation: UInt64) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        for transfer in session.outstandingFileTransfers where Self.fileMetadata(from: transfer.file.metadata)?.kind != .catalogue {
            transfer.cancel()
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "watch-copies-\(generation).pb")
        do {
            try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // With the list that names the Watch, which may not have reached it yet.
            var metadata = Agentkeyring_V2_WatchFileMetadata()
            metadata.kind = .copies
            metadata.generation = generation
            if let members = keyring.signedMembers { metadata.members = members }
            session.transferFile(file, metadata: [Self.pbKey: try metadata.serializedData(), Self.resetAtKey: keyring.watchResetAt])
        } catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Copies not sent to the Watch: \(error)"]) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file.fileURL
        let kind = Self.fileMetadata(from: fileTransfer.file.metadata)?.kind
        try? FileManager.default.removeItem(at: file)
        if let error {
            Task { @MainActor in
                if kind == .catalogue {
                    self.lastSentCatalogue = nil
                    KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Catalogue not delivered to the Watch: \(error)"])
                } else {
                    KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Copies not delivered to the Watch: \(error)"])
                }
            }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let message = Self.decode(session.receivedApplicationContext)
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.keyring.watchPairing(paired: paired, installed: installed)
            if let message { self.receive(message, fromCachedContext: true) }
            self.sendMembers()
            self.sendCatalogueIfNeeded()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "reachability", ["reachable": "\(reachable)"])
            if reachable {
                self.sendMembers(immediate: true)
                self.sendCatalogueIfNeeded()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let message = Self.decode(context) else { return }
        Task { @MainActor in
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "context received", ["hasDevice": "\(message.hasWatchDevice)"])
            self.receive(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let message = Self.decode(userInfo) else { return }
        Task { @MainActor in
            if message.cancelAddWatch {
                self.keyring.cancelWatchOffer(offerID: message.hasAddOfferID ? message.addOfferID : nil)
                self.sendMembers(immediate: true)
                return
            }
            if message.addWatch || message.hasWatchDevice {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "add userInfo received", ["hasOffer": "\(message.hasAddOfferID)"])
                _ = self.receive(message)
                self.sendMembers(immediate: true)
                self.sendCatalogueIfNeeded(force: message.needCatalogue)
                return
            }
            _ = self.receive(message)
            if message.askMembers {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "The Watch asked for Members"])
                self.sendMembers(immediate: true)
                self.sendCatalogueIfNeeded(force: message.needCatalogue)
            }
        }
    }

    /// A live message with no reply wanted: the Watch saying which generation of its copies it holds.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = Self.decode(message) else { return }
        Task { @MainActor in _ = self.receive(decoded) }
    }

    /// Live messages from Apple Watch: Add Watch pairing, Cancel Add, Stop, Try Practice, or fetching Members.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = UncheckedReply(replyHandler)
        guard let decoded = Self.decode(message) else {
            reply.call([:])
            return
        }
        Task { @MainActor in
            // Stop on Apple Watch: the iPhone stops the approval. "stopped" only once it is; "sent" while the
            // asking computer has yet to confirm it.
            if decoded.hasStopRequestID && !decoded.stopRequestID.isEmpty {
                var response = Agentkeyring_V2_PhoneToWatch()
                do {
                    try await self.keyring.endApprovedAccess(decoded.stopRequestID)
                    KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Stopped from Apple Watch"])
                    response.stopped = true
                } catch is PhoneStopNotConfirmed {
                    KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Stop from Apple Watch sent, not yet confirmed"])
                    response.stopped = false
                    response.stopSent = true
                } catch {
                    KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Stop from Apple Watch failed: \(error)"])
                    response.stopped = false
                }
                reply.call(Self.encode(response))
                return
            }
            // Try Practice on Apple Watch: only an iPhone or the Mac can ask the Mac for one.
            if decoded.requestPractice {
                var response = Agentkeyring_V2_PhoneToWatch()
                response.asked = await self.keyring.practiceForWatch()
                reply.call(Self.encode(response))
                return
            }
            if decoded.cancelAddWatch {
                let cancelled = self.keyring.cancelWatchOffer(offerID: decoded.hasAddOfferID ? decoded.addOfferID : nil)
                var response = self.membersMessage
                response.cancelled = cancelled
                reply.call(Self.encode(response))
                return
            }
            if decoded.addWatch || decoded.hasWatchDevice {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "add message received", ["hasOffer": "\(decoded.hasAddOfferID)"])
                let accepted = self.receive(decoded)
                var response = self.membersMessage
                response.accepted = accepted
                reply.call(Self.encode(response))
                self.sendCatalogueIfNeeded(force: decoded.needCatalogue)
                return
            }
            reply.call(Self.encode(self.membersMessage))
            self.sendCatalogueIfNeeded(force: decoded.needCatalogue)
        }
    }

    @discardableResult
    private func receive(_ message: Agentkeyring_V2_WatchToPhone, fromCachedContext: Bool = false) -> Bool {
        let resolvedOfferID = message.hasAddOfferID ? message.addOfferID : ""
        var accepted = false
        if message.hasDismissRequestID && !message.dismissRequestID.isEmpty {
            PhoneDeliveredNotifications.removeRequestNotification(message.dismissRequestID)
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("notification", "removed", ["request": message.dismissRequestID, "by": "watch"])
            keyring.watchDismissedRequest(message.dismissRequestID)
        }
        if message.hasWatchDevice || message.hasWatchPush {
            if message.hasWatchDevice, resolvedOfferID.isEmpty, keyring.activeWatchOfferID != nil {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Watch app needs to update before pairing (no offer ID sent)."])
            }
            accepted = keyring.watchOffered(
                device: message.hasWatchDevice ? message.watchDevice : nil,
                push: message.hasWatchPush ? message.watchPush : nil,
                offerID: resolvedOfferID
            )
        }
        if message.hasSelfTest { keyring.watchTested(message.selfTest) }
        if message.hasCopiesGeneration {
            if !fromCachedContext || message.copiesGeneration >= (keyring.watchCopiesHeld ?? 0) {
                keyring.watchHolds(copiesGeneration: message.copiesGeneration)
            }
        }
        // Apple Watch's recent log lines, kept beside the iPhone's own.
        if !message.logLines.isEmpty {
            KeyringDiagnosticLog.iPhone.mergeLogLines(message.logLines)
        }
        return accepted
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.keyring.watchPairing(paired: paired, installed: installed)
            self.sendMembers()
            self.sendCatalogueIfNeeded()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

struct UncheckedReply: @unchecked Sendable {
    let call: ([String: Any]) -> Void
    init(_ call: @escaping ([String: Any]) -> Void) { self.call = call }
}
