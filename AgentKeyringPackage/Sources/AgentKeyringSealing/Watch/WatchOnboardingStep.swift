// Written by AI on 2026.11.19 by model Claude Opus 5.5; for adding it from the iPhone with Face ID first, 2026.11.21.
// Exhaustive notification handling on 2026.11.27 by model GPT-6.2 Sol.
//
// Where Apple Watch's setup stands, as one state worked out from what the
// Watch can read about itself and the few things it keeps: the lists its
// iPhone sent, whether the iPhone is waiting for it to ask (a held Face ID
// confirmation, with its end), whether he tapped Add, its passcode, what
// watchOS allows, Apple's push address, and whether the practice offer is
// done. It is worked out again whenever one changes, so it cannot drift from
// them. docs/state-machines.md has the table.

import Foundation

public enum WatchNotificationPermission: Sendable { case notAsked, allowed, denied }

public enum WatchOnboardingStep: Equatable, Sendable {
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
                copiesPending: Bool = false, copyingToWatch: Bool = false,
                notifications: WatchNotificationPermission, pushAddress: Bool, practiceAsked: Date?, practiceOfferDone: Bool, now: Date = .now) {
        guard passcode else {
            self = .noPasscode
            return
        }
        guard phoneJoined else {
            self = .setUpIPhone
            return
        }

        if !listed {
            if copyingToWatch || (addTapped && addOffered) {
                self = .preparing
            } else {
                self = addOffered ? .readyToAdd : .startOnIPhone
            }
            return
        }
        if copiesPending {
            self = copyingToWatch ? .preparing : .startOnIPhone
            return
        }

        switch notifications {
        case .notAsked: self = .notifications
        case .denied: self = .notificationsOff
        case .allowed:
            if practiceOfferDone {
                self = .ready
            } else if !pushAddress {
                self = .settingUpNotifications
            } else if let practiceAsked, now.timeIntervalSince(practiceAsked) < Self.practiceWait {
                self = .practiceWaiting
            } else {
                self = .addedOfferPractice
            }
        }
    }
}
