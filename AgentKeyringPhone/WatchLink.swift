// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's side of Apple Watch. The iPhone sends the signed lists and
// settings whenever they change, and "addUntil" while it holds a Face ID
// confirmation for the Watch to be added: only then does the Watch offer Add.
// After Add, the Watch sends its Device and PushRegistration ("watchDevice",
// "watchPush"). Both directions use application context and user info, so it
// works whichever app opens first.

import AgentKeyringPhoneApprover
import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    private let keyring: PhoneKeyring
    /// The end of the held Face ID confirmation, while the iPhone waits for Apple Watch to ask.
    private var addUntil: Date?

    init(keyring: PhoneKeyring) {
        self.keyring = keyring
        super.init()
        keyring.onWatchMayAsk = { [weak self] until in self?.addUntil = until; self?.sendMembers() }
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
        return context
    }

    /// Sends the current lists, settings and Add offer to the Watch.
    func sendMembers() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let context = membersContext
        do { try session.updateApplicationContext(context) } catch { PhoneDiagnostics.note("Lists not sent to the Watch: \(error)") }
        session.transferUserInfo(context)
        PhoneDiagnostics.log.note("watch", "lists sent", ["addOffered": "\(addUntil != nil)"])
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
        Task { @MainActor in
            self.receive(copy)
            if asks { PhoneDiagnostics.note("The Watch asked for Members"); self.sendMembers() }
        }
    }

    /// The Watch has a request it cannot read: it asks for the current list straight away.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = UncheckedReply(replyHandler)
        let stop = message["stop"] as? String
        let practice = message["practice"] != nil
        Task { @MainActor in
            // Stop on Apple Watch: the iPhone holds the request's door and ends the approval there.
            if let stop {
                do { try await self.keyring.stop(stop); PhoneDiagnostics.note("Stopped from Apple Watch"); reply.call(["stopped": true]) }
                catch { PhoneDiagnostics.note("Stop from Apple Watch failed: \(error)"); reply.call(["stopped": false]) }
                return
            }
            // Try Practice on Apple Watch: only an iPhone or the Mac can ask the Mac for one.
            if practice {
                reply.call(["asked": await self.keyring.practiceForWatch()])
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
        return result
    }

    private func receive(_ payload: [String: Data]) {
        if payload["watchDevice"] != nil || payload["watchPush"] != nil {
            keyring.watchOffered(device: payload["watchDevice"], push: payload["watchPush"])
        }
        if let test = payload["watchSelfTest"] { keyring.watchTested(test) }
        // Apple Watch's recent log lines, kept beside the iPhone's own.
        if let data = payload["log"], let lines = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            PhoneDiagnostics.log.merge(lines)
        }
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
