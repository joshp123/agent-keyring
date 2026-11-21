// Written by AI on 2026.11.19 by model Claude Opus 5.5; for adding it from the iPhone with Face ID first, 2026.11.21.
//
// Where Apple Watch's setup stands, as one state worked out from what the
// Watch can read about itself and the few things it keeps: the lists its
// iPhone sent, whether the iPhone is waiting for it to ask (a held Face ID
// confirmation, with its end), whether he tapped Add, its passcode, what
// watchOS allows, Apple's push address, and whether the practice offer is
// done. It is worked out again whenever one changes, so it cannot drift from
// them. docs/state-machines.md has the table.

import Foundation

public enum WatchSetup: Equatable, Sendable {
    case noPasscode
    /// No iPhone has joined a Mac yet.
    case setUpIPhone
    /// The iPhone has joined but is not waiting for this Watch: "Start on your iPhone".
    case startOnIPhone
    /// The iPhone holds a Face ID confirmation for it: "Add this Watch?" with Add.
    case readyToAdd
    /// He tapped Add: the iPhone lists it and encrypts its copies.
    case preparing
    /// Listed: watchOS's own question, raised by Continue.
    case notifications
    case notificationsOff
    case settingUpNotifications
    /// "Apple Watch added", with Try Practice and Done.
    case addedOfferPractice
    /// A practice request has been asked for and has not come yet.
    case practiceWaiting
    case ready

    public enum Notifications: Sendable { case notAsked, allowed, denied }

    /// How long Apple Watch waits for its practice request before offering it again.
    public static let practiceWait: TimeInterval = 60

    /// - Parameters:
    ///   - phoneJoined: the iPhone has sent a signed list of devices.
    ///   - listed: that list names this Apple Watch.
    ///   - addOffered: the iPhone is waiting for this Watch to ask, now.
    ///   - addTapped: he tapped Add on this Watch.
    ///   - practiceAsked: when Try Practice asked for one, if it has not been answered.
    ///   - practiceOfferDone: Done, or a practice answered.
    public init(passcode: Bool, phoneJoined: Bool, listed: Bool, addOffered: Bool, addTapped: Bool,
                notifications: Notifications, pushAddress: Bool, practiceAsked: Date?, practiceOfferDone: Bool, now: Date = .now) {
        self = !passcode ? .noPasscode
            : !phoneJoined ? .setUpIPhone
            : !listed ? (addTapped ? .preparing : addOffered ? .readyToAdd : .startOnIPhone)
            : notifications == .notAsked ? .notifications
            : notifications == .denied ? .notificationsOff
            : !pushAddress ? .settingUpNotifications
            : practiceOfferDone ? .ready
            : practiceAsked.map { now.timeIntervalSince($0) < Self.practiceWait } == true ? .practiceWaiting
            : .addedOfferPractice
    }
}
