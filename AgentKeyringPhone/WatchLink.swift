// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's side of Apple Watch. The iPhone sends the signed lists and
// settings whenever they change, and "addUntil" while it holds a Face ID
// confirmation for the Watch to be added: only then does the Watch offer Add.
// After Add, the Watch sends its Device and PushRegistration ("watchDevice",
// "watchPush"). Both directions use application context and user info, so it
// works whichever app opens first.

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    private let keyring: PhoneKeyring
    /// The end of the held Face ID confirmation, while the iPhone waits for Apple Watch to ask.
    private var addUntil: Date?
    private var addOfferID: String?

    init(keyring: PhoneKeyring) {
        self.keyring = keyring
        super.init()
        keyring.onWatchMayAsk = { [weak self] until, offerID in
            self?.addUntil = until
            self?.addOfferID = offerID
            self?.sendMembers(immediate: true)
        }
        keyring.onListsChanged = { [weak self] in self?.sendMembers(immediate: true) }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var membersContext: [String: Any] {
        var context: [String: Any] = [:]
        if let members = keyring.signedMembers { context["members"] = members }
        // Apple Watch names every request from this signed Catalogue, never from what a push says.
        if let catalogue = keyring.signedCatalogue { context["catalogue"] = catalogue }
        if let settings = try? PropertyListEncoder().encode(keyring.notificationSettings) { context["settings"] = settings }
        if let addUntil { context["addUntil"] = addUntil.timeIntervalSince1970 }
        if let offerID = keyring.activeWatchOfferID ?? addOfferID { context["addOfferID"] = offerID }
        context["copiesPending"] = keyring.watchCopiesPending
        context["copyingToWatch"] = keyring.isCopyingToWatch
        return context
    }

    /// Sends the current lists, settings and Add offer to the Watch.
    /// Uses application context (latest-state replacement, never piles up large FIFO queues)
    /// and a direct live message when the Watch app is reachable for sub-100ms updates.
    func sendMembers(immediate: Bool = false) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let context = membersContext
        do { try session.updateApplicationContext(context) } catch { PhoneDiagnostics.note("Lists not sent to the Watch: \(error)") }
        if immediate, session.isReachable {
            session.sendMessage(context, replyHandler: nil, errorHandler: nil)
        }
        PhoneDiagnostics.log.note("watch", "lists sent", ["addOffered": "\(addUntil != nil)", "reachable": "\(session.isReachable)"])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = Self.plain(session.receivedApplicationContext)
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.keyring.watchPairing(paired: paired, installed: installed)
            self.receive(context)
            self.sendMembers()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let copy = Self.plain(context)
        Task { @MainActor in self.receive(copy) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let copy = Self.plain(userInfo)
        let asks = userInfo["askMembers"] != nil
        let cancelAdd = userInfo["cancelAddWatch"] != nil
        let offerID = userInfo["addOfferID"] as? String
        Task { @MainActor in
            if cancelAdd {
                self.keyring.cancelWatchOffer(offerID: offerID)
                self.sendMembers(immediate: true)
                return
            }
            _ = self.receive(copy)
            if asks { PhoneDiagnostics.note("The Watch asked for Members"); self.sendMembers() }
        }
    }

    /// Live messages from Apple Watch: Add Watch pairing, Cancel Add, Stop, Try Practice, or fetching Members.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = UncheckedReply(replyHandler)
        let stop = message["stop"] as? String
        let practice = message["practice"] != nil
        let cancelAdd = message["cancelAddWatch"] != nil
        let isAddWatch = message["addWatch"] != nil || message["watchDevice"] != nil
        let offerID = message["addOfferID"] as? String
        let copy = Self.plain(message)
        Task { @MainActor in
            // Stop on Apple Watch: the iPhone holds the request's door and ends the approval there.
            if let stop {
                do {
                    try await self.keyring.stop(stop)
                    PhoneDiagnostics.note("Stopped from Apple Watch")
                    reply.call(["stopped": true])
                } catch is PhoneStopWaitsWithMac {
                    PhoneDiagnostics.note("Stop from Apple Watch left with Mac")
                    reply.call(["stopped": true])
                } catch {
                    PhoneDiagnostics.note("Stop from Apple Watch failed: \(error)")
                    reply.call(["stopped": false])
                }
                return
            }
            // Try Practice on Apple Watch: only an iPhone or the Mac can ask the Mac for one.
            if practice {
                reply.call(["asked": await self.keyring.practiceForWatch()])
                return
            }
            if cancelAdd {
                let cancelled = self.keyring.cancelWatchOffer(offerID: offerID)
                var response = self.membersContext
                response["cancelled"] = cancelled
                reply.call(response)
                return
            }
            if isAddWatch {
                let accepted = self.receive(copy, offerID: offerID)
                var response = self.membersContext
                response["accepted"] = accepted
                reply.call(response)
                return
            }
            reply.call(self.membersContext)
        }
    }

    /// The Watch's keys and its self-test, as Data, so they can cross to the main actor.
    nonisolated private static func plain(_ payload: [String: Any]) -> [String: Data] {
        var result = payload.compactMapValues { $0 as? Data }
        if let lines = payload["log"] as? [String] {
            result["log"] = try? PropertyListSerialization.data(fromPropertyList: lines, format: .binary, options: 0)
        }
        if let test = payload["watchSelfTest"] as? [String: Any] {
            result["watchSelfTest"] = try? PropertyListSerialization.data(fromPropertyList: test, format: .binary, options: 0)
        }
        if let offerID = payload["addOfferID"] as? String {
            result["addOfferID"] = Data(offerID.utf8)
        }
        return result
    }

    @discardableResult
    private func receive(_ payload: [String: Data], offerID: String? = nil) -> Bool {
        let resolvedOfferID = offerID ?? payload["addOfferID"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var accepted = false
        if payload["watchDevice"] != nil || payload["watchPush"] != nil {
            if payload["watchDevice"] != nil, resolvedOfferID.isEmpty, keyring.activeWatchOfferID != nil {
                PhoneDiagnostics.note("Watch app needs to update before pairing (no offer ID sent).")
            }
            accepted = keyring.watchOffered(device: payload["watchDevice"], push: payload["watchPush"], offerID: resolvedOfferID)
        }
        if let test = payload["watchSelfTest"] { keyring.watchTested(test) }
        // Apple Watch's recent log lines, kept beside the iPhone's own.
        if let data = payload["log"], let lines = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            PhoneDiagnostics.log.merge(lines)
        }
        return accepted
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        Task { @MainActor in self.keyring.watchPairing(paired: paired, installed: installed); self.sendMembers() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

struct UncheckedReply: @unchecked Sendable {
    let call: ([String: Any]) -> Void
    init(_ call: @escaping ([String: Any]) -> Void) { self.call = call }
}
