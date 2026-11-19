// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's side of setting up the Watch. The Watch app sends its Device
// and PushRegistration once ("watchDevice", "watchPush"); the iPhone sends
// back the signed Members ("members") whenever they change, so the Watch
// knows it has been added. Both directions use application context and user
// info, so it works whichever app opens first.

import AgentKeyringPhoneApprover
import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    private let relay: PhoneRelayBackend

    init(relay: PhoneRelayBackend) {
        self.relay = relay
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var membersContext: [String: Any]? {
        guard let members = relay.signedMembers, let answerURL = relay.relayAnswerURL else { return nil }
        var context: [String: Any] = ["members": members, "relayAnswerURL": answerURL]
        // Apple Watch names every request from this signed Catalogue, not from what the relay sends.
        if let catalogue = relay.signedCatalogue { context["catalogue"] = catalogue }
        if let settings = try? PropertyListEncoder().encode(relay.notificationSettings) { context["settings"] = settings }
        return context
    }

    /// Sends the current signed Members to the Watch.
    func sendMembers() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let members = relay.signedMembers, let answerURL = relay.relayAnswerURL else {
            PhoneDiagnostics.note("Members not sent to the Watch: activated \(WCSession.default.activationState == .activated), paired \(WCSession.default.isPaired), installed \(WCSession.default.isWatchAppInstalled), members \(relay.signedMembers != nil)")
            return
        }
        let context: [String: Any] = membersContext ?? ["members": members, "relayAnswerURL": answerURL]
        do { try session.updateApplicationContext(context) } catch { PhoneDiagnostics.note("Members not sent to the Watch: \(error)") }
        session.transferUserInfo(context)
        PhoneDiagnostics.note("Members sent to the Watch (\(members.count) bytes)")
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = Self.plain(session.receivedApplicationContext)
        let paired = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in
            self.relay.watchPaired = paired
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
        Task { @MainActor in
            // Stop on Apple Watch: it cannot reach the relay's device methods, so the iPhone ends the approval.
            if let stop {
                do { try await self.relay.stop(stop); PhoneDiagnostics.note("Stopped from Apple Watch"); reply.call(["stopped": true]) }
                catch { PhoneDiagnostics.note("Stop from Apple Watch failed: \(error)"); reply.call(["stopped": false]) }
                return
            }
            PhoneDiagnostics.note("The Watch asked for Members at once")
            reply.call(self.membersContext ?? [:])
        }
    }

    /// The Watch's keys and its self-test, as Data, so they can cross to the main actor.
    nonisolated private static func plain(_ payload: [String: Any]) -> [String: Data] {
        var result = payload.compactMapValues { $0 as? Data }
        if let test = payload["watchSelfTest"] as? [String: Any] {
            result["watchSelfTest"] = try? PropertyListSerialization.data(fromPropertyList: test, format: .binary, options: 0)
        }
        return result
    }

    private func receive(_ payload: [String: Data]) {
        if payload["watchDevice"] != nil || payload["watchPush"] != nil {
            relay.watchOffered(device: payload["watchDevice"], push: payload["watchPush"])
        }
        if let test = payload["watchSelfTest"] { relay.watchTested(test) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in self.relay.watchPaired = paired; self.sendMembers() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

struct UncheckedReply: @unchecked Sendable {
    let call: ([String: Any]) -> Void
    init(_ call: @escaping ([String: Any]) -> Void) { self.call = call }
}
