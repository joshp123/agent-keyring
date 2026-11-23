// Written by AI on 2026.11.23 by model gemini-4-neon.
import AgentKeyringApprovalCore
import AgentKeyringFeature
import AgentKeyringProtocol
import Foundation
import Testing

@Suite("Blind push relay & version check")
struct PushRelayAndVersionTests {
    @Test("VersionCheck monthly anonymous ID is deterministic within a month and rotates across months")
    func monthlyAnonymousIDRotates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nov1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let nov23 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        let dec1 = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!

        let a = VersionCheck.monthlyAnonymousID(seed: "test-seed", now: nov1)
        let b = VersionCheck.monthlyAnonymousID(seed: "test-seed", now: nov23)
        let c = VersionCheck.monthlyAnonymousID(seed: "test-seed", now: dec1)

        #expect(a.count == 16)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("ApplePush relay mode initializes without a .p8 key and points at defaultRelayURL")
    func applePushRelayInit() {
        let push = ApplePush(relayURL: ApplePush.defaultRelayURL)
        #expect(ApplePush.defaultRelayURL.absoluteString == "https://push.opentrawl.sh")
        _ = push
    }
}
