// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// Apple Watch keeps the relay its iPhone uses, so it can answer requests from
// computers enrolled on a self-hosted relay: kept across a relaunch, cleared
// when the iPhone goes back to the default, and kept when a message says nothing.

import AgentKeyringProtocol
@testable import AgentKeyringSealing
import Foundation
import Testing

struct WatchRelayTests {
    private func context(sentAt: Double, relay: String?) -> Agentkeyring_V2_PhoneToWatch {
        var message = Agentkeyring_V2_PhoneToWatch()
        message.sentAtUnixSeconds = sentAt
        if let relay { message.relayURL = relay }
        return message
    }

    private func merged(_ message: Agentkeyring_V2_PhoneToWatch, into saved: WatchPersistedState) throws -> WatchPersistedState {
        let update = try #require(WatchStateCoordinator.merge(message, into: saved, current: true, keyID: "watch", now: .now))
        return try #require(WatchPersistedState.decodeProtobuf(update.saved.encodeProtobuf()))
    }

    @Test func theIPhonesRelayIsKeptUntilItSaysOtherwise() throws {
        let custom = try merged(context(sentAt: 10, relay: "https://relay.example"), into: WatchPersistedState())
        #expect(custom.relayURL == "https://relay.example")
        let silent = try merged(context(sentAt: 11, relay: nil), into: custom)
        #expect(silent.relayURL == "https://relay.example")
        // An older context, delivered late, changes nothing.
        let late = try merged(context(sentAt: 9, relay: ""), into: silent)
        #expect(late.relayURL == "https://relay.example")
        let backToDefault = try merged(context(sentAt: 12, relay: ""), into: late)
        #expect(backToDefault.relayURL == nil)
    }
}
