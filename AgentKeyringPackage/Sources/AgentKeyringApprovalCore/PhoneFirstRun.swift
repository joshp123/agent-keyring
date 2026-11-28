// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// First run on the iPhone as one explicit state (Paper, "First run and the
// app", board "iPhone and Apple Watch", iPhone first run). Each case is one picture on the board and each event one of its
// captions. The backend sends it events and does what the state asks; nothing
// else decides where first run stands. Timers stay outside and arrive as
// events. docs/state-machines.md has the table.

import Foundation

public enum PhoneFirstRunEvent: Hashable, Sendable {
    /// The look found the Mac's join card, or found none.
    case macFound(name: String?)
    case macGone
    /// The first look found no card.
    case noMacFound
    /// "Already set up on your Mac?"
    case havingTrouble
    case tryAgain
    case connect
    case cancel
    case joinRefused
    case macUnreachable
    case joinExpired
    case askAgain
    case joined
    case passwordsReceived
    /// "Set Up on This iPhone" done: this iPhone has its own list of devices, with only itself.
    case setUpHere
    /// The copy from Passwords arrived and was sealed, or Skip for Now.
    case passwordsImported
    case continueTapped
    case notificationsAnswered(allowed: Bool)
    /// Continue on the checklist, once iOS has answered.
    case notificationsDone
    case continueWithoutNotifications
    /// The practice request this iPhone made, or the one already waiting.
    case practiceSent(id: String)
    /// `pushExpected`: its notification will come, so it waits for a tap.
    case practiceArrived(pushExpected: Bool)
    case practiceTapped
    /// Cancel on the practice sheet: keeps the practice request available to open again.
    case practiceDismissed
    /// 30 seconds after asking. `pushAddress`: Apple has given one.
    case practiceTimedOut(pushAddress: Bool)
    /// The practice request could not be sent.
    case practiceMacUnreachable
    /// Send Practice Request, Send Another or Try Again, with a new id (`newPracticeID()`).
    case sendPractice(id: String)
    case practiceEnded(PhonePracticeOutcome)
    /// Continue or Skip for Now after the practice. `watchToAdd`: an Apple Watch is paired and not yet added.
    case continueAfterPractice(watchToAdd: Bool)
    case addAppleWatch
    case addAComputer
    /// Done, or the Apple Watch or computer flow closed.
    case done
    /// This iPhone was taken out of the list of devices.
    case removed
}

public enum PhoneFirstRun: Hashable, Sendable {
    /// Reading iCloud Keychain for another device's join card, for a moment: the read is local, and a card
    /// iCloud has just brought may still be on its way.
    case searching
    /// No card found: "Set Up on This iPhone", and "Already set up on your Mac?". The look goes on, so a
    /// card that arrives later still offers Connect.
    case welcome
    /// "Check these four things", from "Already set up on your Mac?", with Try Again and Back.
    case trouble
    /// "Continue setup from <Mac>", with Connect and Set Up on This iPhone. Nothing is asked of the Mac until he taps Connect.
    case foundMac(name: String?)
    /// He tapped Connect: the request to join waits on the Mac. Saved, so leaving the app or relaunching
    /// it picks up the same request instead of starting again; a dropped connection is still waiting.
    case waitingForMac(name: String?)
    /// The Mac refused, with Ask Again and Cancel. Nothing asks again by itself.
    case deniedByMac(name: String?)
    /// The request to join could not be put in iCloud, or iCloud is not available, with Try Again and Cancel.
    case cantReachMac(name: String?)
    /// Ten minutes passed with no answer from the Mac, with Ask Again and Cancel.
    case expired(name: String?)
    /// Added: this iPhone's copies of the passwords are arriving.
    case receivingPasswords
    /// Set up on this iPhone, with no Mac: "Copy your passwords" from Passwords on this iPhone, or Skip for Now.
    case importPasswords
    /// "Turn on notifications", with Continue.
    case notifications
    /// iOS's own question is up.
    case askingNotifications
    case notificationsOff
    /// "Try a practice notification", with Send Practice Request and Skip for Now.
    case practiceOffer
    /// A practice request has been asked for. `id`: chosen by this iPhone and saved, so asking again with it
    /// rejoins the same request on a return to the app. `arrived`: it is here, and its notification waits for a tap.
    case practiceWaiting(id: String, arrived: Bool)
    /// 30 seconds passed and Apple has given no push address: the practice request opens by itself when it arrives.
    case settingUpNotifications(id: String)
    /// 30 seconds passed and nothing arrived, though Apple gave an address.
    case practiceNotArrived(id: String)
    /// This iPhone could not send its practice request (its name is from when the Mac made them; it is saved).
    /// Try Again, Skip for Now.
    case practiceMacUnreachable(id: String)
    /// The practice request is open.
    case practice(id: String)
    /// The practice's result stays on screen, with Send Another and Continue.
    case practiceResult(PhonePracticeOutcome)
    /// "Add your Apple Watch?" with Add Apple Watch, only when one is paired and not added; otherwise Done alone.
    case readyOfferWatch(watchToAdd: Bool)
    /// Adding Apple Watch, in its own flow (`PhoneAddWatch`).
    case addWatch
    /// Add a Computer from Ready, when no computer or Mac is added yet: the one-time code (`PhoneAddComputer`).
    case addComputer
    /// First run is over: the app's tabs, Home first.
    case finished

    public static let start = PhoneFirstRun.searching

    /// The next state. Each state lists every event: the ones it moves on, and the ones it ignores, so a
    /// repeated tap or a late answer cannot move first run anywhere wrong, and a new state or event does not
    /// compile until every pair says what it does. Removal always starts again.
    public func on(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch self {
        case .searching: onSearching(event)
        case .welcome: onWelcome(event)
        case .trouble: onTrouble(event)
        case let .foundMac(name): onFoundMac(name: name, event)
        case let .waitingForMac(name): onWaitingForMac(name: name, event)
        case let .deniedByMac(name): onDeniedByMac(name: name, event)
        case let .cantReachMac(name): onCantReachMac(name: name, event)
        case let .expired(name): onExpired(name: name, event)
        case .receivingPasswords: onReceivingPasswords(event)
        case .importPasswords: onImportPasswords(event)
        case .notifications: onNotifications(event)
        case .askingNotifications: onAskingNotifications(event)
        case .notificationsOff: onNotificationsOff(event)
        case .practiceOffer: onPracticeOffer(event)
        case let .practiceWaiting(id, arrived): onPracticeWaiting(id: id, arrived: arrived, event)
        case let .settingUpNotifications(id): onSettingUpNotifications(id: id, event)
        case let .practiceNotArrived(id): onPracticeNotArrived(id: id, event)
        case .practiceMacUnreachable: onPracticeMacUnreachable(event)
        case let .practice(id): onPractice(id: id, event)
        case .practiceResult: onPracticeResult(event)
        case let .readyOfferWatch(watchToAdd): onReadyOfferWatch(watchToAdd: watchToAdd, event)
        case .addWatch: onAddWatch(event)
        case .addComputer: onAddComputer(event)
        case .finished: onFinished(event)
        }
    }

    /// Where first run picks up after the app was closed. What the look found is found again. A question
    /// iOS was asking did not outlive the app. A request to join, or a practice request, is picked up by
    /// the same request.
    public var restored: PhoneFirstRun {
        switch self {
        case .searching, .welcome, .trouble, .foundMac: .start
        case .askingNotifications: .notifications
        case let .practiceWaiting(id, _), let .settingUpNotifications(id), let .practiceNotArrived(id), let .practice(id):
            .practiceWaiting(id: id, arrived: false)
        case .waitingForMac, .deniedByMac, .cantReachMac, .expired, .receivingPasswords, .importPasswords, .notifications,
             .notificationsOff, .practiceOffer, .practiceMacUnreachable, .practiceResult, .readyOfferWatch, .addWatch,
             .addComputer, .finished: self
        }
    }

    /// The iPhone asks the Mac to join only here, after Connect.
    public var mayJoin: Bool {
        if case .waitingForMac = self { true } else { false }
    }

    /// The look for the Mac's join card runs before Connect (not while on the manual Trouble checklist).
    public var looksForMac: Bool {
        switch self {
        case .searching, .welcome, .foundMac, .waitingForMac: true
        case .trouble, .deniedByMac, .cantReachMac, .expired, .receivingPasswords, .importPasswords, .notifications,
             .askingNotifications, .notificationsOff, .practiceOffer, .practiceWaiting, .settingUpNotifications,
             .practiceNotArrived, .practiceMacUnreachable, .practice, .practiceResult, .readyOfferWatch, .addWatch,
             .addComputer, .finished: false
        }
    }

    /// The practice request first run is waiting on or showing.
    public var practiceID: String? {
        switch self {
        case let .practiceWaiting(id, _), let .settingUpNotifications(id), let .practiceNotArrived(id), let .practice(id): id
        case .searching, .welcome, .trouble, .foundMac, .waitingForMac, .deniedByMac, .cantReachMac, .expired,
             .receivingPasswords, .importPasswords, .notifications, .askingNotifications, .notificationsOff, .practiceOffer,
             .practiceMacUnreachable, .practiceResult, .readyOfferWatch, .addWatch, .addComputer, .finished: nil
        }
    }

    /// A new practice request's id: 32 hex digits, chosen by the asker.
    public static func newPracticeID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// One transition per state, each listing every event, so `on(_:)` stays one readable table.
extension PhoneFirstRun {
    private func onSearching(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .macFound(name): .foundMac(name: name)
        case .noMacFound: .welcome
        case .setUpHere: .importPasswords
        case .removed: .start
        case .macGone, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused, .macUnreachable, .joinExpired,
             .askAgain, .joined, .passwordsReceived, .passwordsImported, .continueTapped, .notificationsAnswered,
             .notificationsDone, .continueWithoutNotifications, .practiceSent, .practiceArrived, .practiceTapped,
             .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable, .sendPractice, .practiceEnded,
             .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onWelcome(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .macFound(name): .foundMac(name: name)
        case .havingTrouble: .trouble
        case .setUpHere: .importPasswords
        case .removed: .start
        case .macGone, .noMacFound, .tryAgain, .connect, .cancel, .joinRefused, .macUnreachable, .joinExpired,
             .askAgain, .joined, .passwordsReceived, .passwordsImported, .continueTapped, .notificationsAnswered,
             .notificationsDone, .continueWithoutNotifications, .practiceSent, .practiceArrived, .practiceTapped,
             .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable, .sendPractice, .practiceEnded,
             .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onTrouble(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .cancel: .welcome
        case .tryAgain: .start
        case .setUpHere: .importPasswords
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .connect, .joinRefused, .macUnreachable, .joinExpired,
             .askAgain, .joined, .passwordsReceived, .passwordsImported, .continueTapped, .notificationsAnswered,
             .notificationsDone, .continueWithoutNotifications, .practiceSent, .practiceArrived, .practiceTapped,
             .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable, .sendPractice, .practiceEnded,
             .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onFoundMac(name: String?, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .macGone: .start
        case .connect: .waitingForMac(name: name)
        case .setUpHere: .importPasswords
        case .removed: .start
        case .macFound, .noMacFound, .havingTrouble, .tryAgain, .cancel, .joinRefused, .macUnreachable, .joinExpired,
             .askAgain, .joined, .passwordsReceived, .passwordsImported, .continueTapped, .notificationsAnswered,
             .notificationsDone, .continueWithoutNotifications, .practiceSent, .practiceArrived, .practiceTapped,
             .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable, .sendPractice, .practiceEnded,
             .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onWaitingForMac(name: String?, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .cancel: .foundMac(name: name)
        case .joinRefused: .deniedByMac(name: name)
        case .macUnreachable: .cantReachMac(name: name)
        case .joinExpired: .expired(name: name)
        case .joined: .receivingPasswords
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .askAgain, .passwordsReceived,
             .setUpHere, .passwordsImported, .continueTapped, .notificationsAnswered, .notificationsDone,
             .continueWithoutNotifications, .practiceSent, .practiceArrived, .practiceTapped, .practiceDismissed,
             .practiceTimedOut, .practiceMacUnreachable, .sendPractice, .practiceEnded, .continueAfterPractice,
             .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onDeniedByMac(name: String?, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .cancel: .foundMac(name: name)
        case .askAgain: .waitingForMac(name: name)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .joinRefused, .macUnreachable,
             .joinExpired, .joined, .passwordsReceived, .setUpHere, .passwordsImported, .continueTapped,
             .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onCantReachMac(name: String?, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .cancel: .foundMac(name: name)
        case .tryAgain: .waitingForMac(name: name)
        case .setUpHere: .importPasswords
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .connect, .joinRefused, .macUnreachable, .joinExpired,
             .askAgain, .joined, .passwordsReceived, .passwordsImported, .continueTapped, .notificationsAnswered,
             .notificationsDone, .continueWithoutNotifications, .practiceSent, .practiceArrived, .practiceTapped,
             .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable, .sendPractice, .practiceEnded,
             .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onExpired(name: String?, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .cancel: .foundMac(name: name)
        case .askAgain: .waitingForMac(name: name)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .joinRefused, .macUnreachable,
             .joinExpired, .joined, .passwordsReceived, .setUpHere, .passwordsImported, .continueTapped,
             .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onReceivingPasswords(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .passwordsReceived: .notifications
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .setUpHere, .passwordsImported, .continueTapped,
             .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onImportPasswords(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .passwordsImported: .notifications
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .continueTapped,
             .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onNotifications(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .continueTapped: .askingNotifications
        case .notificationsDone, .continueWithoutNotifications: .practiceOffer
        case let .notificationsAnswered(allowed): allowed ? self : .notificationsOff
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .practiceSent, .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut,
             .practiceMacUnreachable, .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch,
             .addAComputer, .done: self
        }
    }

    private func onAskingNotifications(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .notificationsAnswered(allowed): allowed ? .notifications : .notificationsOff
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsDone, .continueWithoutNotifications, .practiceSent, .practiceArrived,
             .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable, .sendPractice,
             .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onNotificationsOff(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .notificationsAnswered(allowed): allowed ? .notifications : self
        case .continueWithoutNotifications: .practiceOffer
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsDone, .practiceSent, .practiceArrived, .practiceTapped, .practiceDismissed,
             .practiceTimedOut, .practiceMacUnreachable, .sendPractice, .practiceEnded, .continueAfterPractice,
             .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onPracticeOffer(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .sendPractice(id): .practiceWaiting(id: id, arrived: false)
        case let .continueAfterPractice(watchToAdd): .readyOfferWatch(watchToAdd: watchToAdd)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .practiceEnded, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onPracticeWaiting(id: String, arrived: Bool, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .sendPractice(next): .practiceWaiting(id: next, arrived: false)
        case .practiceMacUnreachable: arrived ? self : .practiceMacUnreachable(id: id)
        case let .practiceSent(next): .practiceWaiting(id: next, arrived: arrived)
        case let .practiceArrived(pushExpected): arrived ? self : pushExpected ? .practiceWaiting(id: id, arrived: true) : .practice(id: id)
        case .practiceTapped: .practice(id: id)
        case let .practiceTimedOut(pushAddress): arrived ? self : pushAddress ? .practiceNotArrived(id: id) : .settingUpNotifications(id: id)
        case let .practiceEnded(outcome): .practiceResult(outcome)
        case let .continueAfterPractice(watchToAdd): .readyOfferWatch(watchToAdd: watchToAdd)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications,
             .practiceDismissed, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onSettingUpNotifications(id: String, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .sendPractice(next): .practiceWaiting(id: next, arrived: false)
        case .practiceMacUnreachable: .practiceMacUnreachable(id: id)
        case let .practiceSent(next): .settingUpNotifications(id: next)
        case .practiceArrived, .practiceTapped: .practice(id: id)
        case let .practiceEnded(outcome): .practiceResult(outcome)
        case let .continueAfterPractice(watchToAdd): .readyOfferWatch(watchToAdd: watchToAdd)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications,
             .practiceDismissed, .practiceTimedOut, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onPracticeNotArrived(id: String, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .sendPractice(next): .practiceWaiting(id: next, arrived: false)
        case let .practiceSent(next): .practiceNotArrived(id: next)
        case .practiceArrived, .practiceTapped: .practice(id: id)
        case let .practiceEnded(outcome): .practiceResult(outcome)
        case let .continueAfterPractice(watchToAdd): .readyOfferWatch(watchToAdd: watchToAdd)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications,
             .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onPracticeMacUnreachable(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .sendPractice(next): .practiceWaiting(id: next, arrived: false)
        case let .continueAfterPractice(watchToAdd): .readyOfferWatch(watchToAdd: watchToAdd)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .practiceEnded, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onPractice(id: String, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .sendPractice(next): .practiceWaiting(id: next, arrived: false)
        case .practiceDismissed: .practiceWaiting(id: id, arrived: true)
        case let .practiceEnded(outcome): .practiceResult(outcome)
        case let .continueAfterPractice(watchToAdd): .readyOfferWatch(watchToAdd: watchToAdd)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceTimedOut, .practiceMacUnreachable, .addAppleWatch,
             .addAComputer, .done: self
        }
    }

    private func onPracticeResult(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case let .sendPractice(id): .practiceWaiting(id: id, arrived: false)
        case let .continueAfterPractice(watchToAdd): .readyOfferWatch(watchToAdd: watchToAdd)
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .practiceEnded, .addAppleWatch, .addAComputer, .done: self
        }
    }

    private func onReadyOfferWatch(watchToAdd: Bool, _ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .addAppleWatch: watchToAdd ? .addWatch : self
        case .addAComputer: .addComputer
        case .done: .finished
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice: self
        }
    }

    private func onAddWatch(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .done: .finished
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer: self
        }
    }

    private func onAddComputer(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .done: .finished
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer: self
        }
    }

    private func onFinished(_ event: PhoneFirstRunEvent) -> PhoneFirstRun {
        switch event {
        case .removed: .start
        case .macFound, .macGone, .noMacFound, .havingTrouble, .tryAgain, .connect, .cancel, .joinRefused,
             .macUnreachable, .joinExpired, .askAgain, .joined, .passwordsReceived, .setUpHere, .passwordsImported,
             .continueTapped, .notificationsAnswered, .notificationsDone, .continueWithoutNotifications, .practiceSent,
             .practiceArrived, .practiceTapped, .practiceDismissed, .practiceTimedOut, .practiceMacUnreachable,
             .sendPractice, .practiceEnded, .continueAfterPractice, .addAppleWatch, .addAComputer, .done: self
        }
    }
}

/// How a practice request ended, for the screen that stays up after it.
public enum PhonePracticeOutcome: Hashable, Sendable {
    case approved, denied, noAnswer
}

extension AccessRequest {
    /// The practice request id before joining, when it never leaves this iPhone.
    public static let localPracticeID = "practice"

    /// A practice request: it names no computer, and carries the practice words.
    public var isPractice: Bool { agent.machine.isEmpty && agent.name == PhoneCopy.practiceAgent }

    /// The practice request in the real request's layout, with the board's words.
    public static func practiceAccessRequest(id: String = localPracticeID, askedAt: Date = .now, until: Date = .now.addingTimeInterval(600)) -> AccessRequest {
        AccessRequest(id: id, login: RequestedLogin(site: PhoneCopy.practiceSite, account: PhoneCopy.practiceAccount),
                      agent: RequestingAgent(name: PhoneCopy.practiceAgent, machine: "", address: ""),
                      access: .login, agentReason: PhoneCopy.practiceReason, askedAt: askedAt, state: .waitingForYou(until: until))
    }
}
