// Written by AI on 2026.11.20 by model claude opus 5.5.
// Josh denies an agent on this Mac: it may ask again a minute later, five
// minutes after a second denial in a row, fifteen after more; an hour with
// no denial starts again at a minute. It reads when, and his words.

@testable import AgentKeyringFeature
import Foundation
import Testing

struct DenialHoldTests {
    typealias Hold = CredentialLeaseStore.Suppression

    @Test("Each denial in a row holds the agent off longer; an hour later it starts again")
    func growing() {
        let first = Hold.after(nil, reply: "Use the work account.", now: 1000)
        #expect(first.until == 1060)
        let second = Hold.after(first, reply: "", now: 1100)
        #expect(second.until == 1400)
        let third = Hold.after(second, reply: "", now: 1500)
        #expect(third.until == 2400)
        #expect(Hold.after(third, reply: "", now: 2400 + 3601).until == 2400 + 3601 + 60)
    }

    @MainActor @Test("The agent is told when it may ask again, and his words exactly")
    func told() {
        let line = CredentialLeaseStore.heldOff(1060, reply: "Use the work account.")
        #expect(line.contains("Ask again after"))
        #expect(line.hasSuffix("His reply, word for word: \"Use the work account.\""))
    }
}
