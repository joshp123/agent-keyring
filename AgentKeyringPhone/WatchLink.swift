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

    /// Sends the current signed Members to the Watch.
    func sendMembers() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let members = relay.signedMembers, let answerURL = relay.relayAnswerURL else {
            PhoneDiagnostics.note("Members not sent to the Watch: activated \(WCSession.default.activationState == .activated), paired \(WCSession.default.isPaired), installed \(WCSession.default.isWatchAppInstalled), members \(relay.signedMembers != nil)")
            return
        }
        let context: [String: Any] = ["members": members, "relayAnswerURL": answerURL]
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
        Task { @MainActor in self.receive(copy) }
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
