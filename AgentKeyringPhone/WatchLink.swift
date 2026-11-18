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
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let members = relay.signedMembers else { return }
        try? WCSession.default.updateApplicationContext(["members": members])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext.compactMapValues { $0 as? Data }
        Task { @MainActor in
            self.receive(context)
            self.sendMembers()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let copy = context.compactMapValues { $0 as? Data }
        Task { @MainActor in self.receive(copy) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let copy = userInfo.compactMapValues { $0 as? Data }
        Task { @MainActor in self.receive(copy) }
    }

    private func receive(_ payload: [String: Data]) {
        guard let device = payload["watchDevice"], let push = payload["watchPush"] else { return }
        relay.watchOffered(device: device, push: push)
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
