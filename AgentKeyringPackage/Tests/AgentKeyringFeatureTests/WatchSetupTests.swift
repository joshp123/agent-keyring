// Written by AI on 2026.11.19 by model Claude Opus 5.5; Add offered only while the iPhone waits, 2026.11.21.
// Apple Watch asks about notifications only once its iPhone has added it, and
// offers Add only while its iPhone holds a Face ID confirmation for it: before,
// it asked about notifications the first time it was opened, and sent its keys
// by itself whenever it opened.

import AgentKeyringWatchCore
import Foundation
import Testing

struct WatchSetupTests {
    func setup(listed: Bool = false, addOffered: Bool = false, addTapped: Bool = false,
               notifications: WatchSetup.Notifications = .allowed, practiceAsked: Date? = nil, done: Bool = false) -> WatchSetup {
        WatchSetup(passcode: true, phoneJoined: true, listed: listed, addOffered: addOffered, addTapped: addTapped,
                   notifications: notifications, pushAddress: true, practiceAsked: practiceAsked, practiceOfferDone: done,
                   now: Date(timeIntervalSince1970: 1000))
    }

    @Test func addIsOfferedOnlyWhileTheIPhoneWaits() {
        #expect(setup() == .startOnIPhone)
        #expect(setup(addOffered: true) == .readyToAdd)
        #expect(setup(addTapped: true) == .preparing)
    }

    @Test func notificationsComeOnlyAfterTheIPhoneAddsIt() {
        #expect(setup(notifications: .notAsked) == .startOnIPhone)
        #expect(setup(listed: true, notifications: .notAsked) == .notifications)
    }

    @Test func thePracticeIsOfferedAgainIfItNeverCame() {
        #expect(setup(listed: true) == .addedOfferPractice)
        #expect(setup(listed: true, practiceAsked: Date(timeIntervalSince1970: 990)) == .practiceWaiting)
        #expect(setup(listed: true, practiceAsked: Date(timeIntervalSince1970: 900)) == .addedOfferPractice)
        #expect(setup(listed: true, done: true) == .ready)
    }
}
