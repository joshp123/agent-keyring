// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// Where Apple Watch's setup stands (Paper, "First run", Apple Watch row), as
// one state worked out from what the Watch can read about itself: the list of
// devices the iPhone sent, its passcode, what watchOS allows and Apple's push
// address. None of these is kept by the app, so the state cannot drift from
// them; it is worked out again whenever one changes. docs/state-machines.md
// has the table.

public enum WatchSetup: Equatable, Sendable {
    case noPasscode
    case setUpIPhone
    case approveOnIPhone
    /// "Answer on your wrist", with Continue, which raises watchOS's question.
    case notifications
    case notificationsOff
    case settingUpNotifications
    case ready

    public enum Notifications: Sendable { case notAsked, allowed, denied }

    /// - Parameters:
    ///   - phoneJoined: the iPhone has sent a signed list of devices.
    ///   - listed: that list names this Apple Watch.
    public init(passcode: Bool, phoneJoined: Bool, listed: Bool, notifications: Notifications, pushAddress: Bool) {
        self = !passcode ? .noPasscode
            : !phoneJoined ? .setUpIPhone
            : !listed ? .approveOnIPhone
            : notifications == .notAsked ? .notifications
            : notifications == .denied ? .notificationsOff
            : !pushAddress ? .settingUpNotifications
            : .ready
    }
}
