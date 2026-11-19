// Written by AI on 2026.11.19 by model Claude Opus 5.5.
// Apple Watch asks about notifications only once its iPhone has added it
// (Paper, "First run", Apple Watch row). Before, it asked the first time it
// was opened, even before an iPhone was set up.

import AgentKeyringWatchCore
import Testing

struct WatchSetupTests {
    @Test func notificationsComeOnlyAfterTheIPhoneAddsIt() {
        let notifications: [WatchSetup.Notifications] = [.notAsked, .allowed, .denied]
        for passcode in [false, true] { for phoneJoined in [false, true] { for listed in [false, true] {
            for asked in notifications { for pushAddress in [false, true] {
                let setup = WatchSetup(passcode: passcode, phoneJoined: phoneJoined, listed: listed, notifications: asked, pushAddress: pushAddress)
                if [.notifications, .notificationsOff, .settingUpNotifications, .ready].contains(setup) {
                    #expect(passcode && phoneJoined && listed)
                }
            } }
        } } }
        #expect(WatchSetup(passcode: true, phoneJoined: true, listed: true, notifications: .notAsked, pushAddress: true) == .notifications)
        #expect(WatchSetup(passcode: true, phoneJoined: true, listed: false, notifications: .allowed, pushAddress: true) == .approveOnIPhone)
    }
}
