// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// First run on the iPhone as one explicit state (Paper, "First run and the
// app", board "iPhone and Apple Watch", iPhone first run). Each case is one picture on the board and each event one of its
// captions. The backend sends it events and does what the state asks; nothing
// else decides where first run stands. Timers stay outside and arrive as
// events. docs/state-machines.md has the table.

import Foundation

public enum PhoneFirstRun: Hashable, Sendable, Codable {
    /// Looking for the Mac's join card in iCloud Keychain. The read is local and instant; iCloud's sync
    /// between devices can take minutes. `longWait`: two minutes with nothing found.
    case searching(longWait: Bool)
    /// "Check these three things", after two minutes or Having Trouble, with Try Again.
    case trouble
    /// "Continue setup from <Mac>", with Connect. Nothing is asked of the Mac until he taps it.
    case foundMac(name: String?)
    /// He tapped Connect: the request to join waits on the Mac. Saved, so leaving the app or relaunching
    /// it picks up the same request instead of starting again; a dropped connection is still waiting.
    case waitingForMac(name: String?)
    /// The Mac refused, with Ask Again and Cancel. Nothing asks again by itself.
    case deniedByMac(name: String?)
    /// The Mac could not be reached at all, with Try Again and Cancel.
    case cantReachMac(name: String?)
    /// Ten minutes passed with no answer from the Mac, with Ask Again and Cancel.
    case expired(name: String?)
    /// Added: this iPhone's copies of the passwords are arriving.
    case receivingPasswords
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
    /// The Mac makes practice requests and could not be reached: it must be awake. Try Again, Skip for Now.
    case practiceMacUnreachable(id: String)
    /// The practice request is open.
    case practice(id: String)
    /// The practice's result stays on screen, with Send Another and Continue.
    case practiceResult(PhonePracticeOutcome)
    /// "Add your Apple Watch?" with Add Apple Watch, only when one is paired and not added; otherwise Done alone.
    case readyOfferWatch(watchToAdd: Bool)
    /// Adding Apple Watch, in its own flow (`PhoneAddWatch`).
    case addWatch
    /// First run is over: the app's tabs, Home first.
    case finished

    public enum Event: Hashable, Sendable {
        /// The look found the Mac's join card, or found none.
        case macFound(name: String?)
        case macGone
        /// Two minutes of looking with nothing found.
        case lookedLong
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
        case continueTapped
        case notificationsAnswered(allowed: Bool)
        case continueWithoutNotifications
        /// The relay names the practice request it made or already had waiting.
        case practiceSent(id: String)
        /// `pushExpected`: its notification will come, so it waits for a tap.
        case practiceArrived(pushExpected: Bool)
        case practiceTapped
        /// 30 seconds after asking. `pushAddress`: Apple has given one.
        case practiceTimedOut(pushAddress: Bool)
        /// The Mac's door could not be reached to ask for the practice request.
        case practiceMacUnreachable
        /// Send Practice Request, Send Another or Try Again, with a new id (`newPracticeID()`).
        case sendPractice(id: String)
        case practiceEnded(PhonePracticeOutcome)
        /// Continue or Skip for Now after the practice. `watchToAdd`: an Apple Watch is paired and not yet added.
        case continueAfterPractice(watchToAdd: Bool)
        case addAppleWatch
        /// Done, or the Apple Watch flow closed.
        case done
        /// This iPhone was taken out of the list of devices.
        case removed
    }

    public static let start = PhoneFirstRun.searching(longWait: false)

    /// The next state. A pair the table does not list leaves the state as it is,
    /// so a repeated tap or a late answer cannot move first run anywhere wrong.
    public func on(_ event: Event) -> PhoneFirstRun {
        switch (self, event) {
        case (_, .removed): .start
        case let (.searching, .macFound(name)), let (.trouble, .macFound(name)): .foundMac(name: name)
        case (.searching(false), .lookedLong), (.searching, .havingTrouble), (.foundMac, .havingTrouble): .trouble
        case (.trouble, .tryAgain), (.trouble, .cancel), (.foundMac, .macGone): .start
        case let (.foundMac(name), .connect): .waitingForMac(name: name)
        case let (.waitingForMac(name), .cancel), let (.deniedByMac(name), .cancel), let (.cantReachMac(name), .cancel),
             let (.expired(name), .cancel): .foundMac(name: name)
        case let (.waitingForMac(name), .joinRefused): .deniedByMac(name: name)
        case let (.waitingForMac(name), .macUnreachable): .cantReachMac(name: name)
        case let (.waitingForMac(name), .joinExpired): .expired(name: name)
        case let (.deniedByMac(name), .askAgain), let (.expired(name), .askAgain), let (.cantReachMac(name), .tryAgain):
            .waitingForMac(name: name)
        case (.waitingForMac, .joined): .receivingPasswords
        case (.receivingPasswords, .passwordsReceived): .notifications
        case (.notifications, .continueTapped): .askingNotifications
        case (.notifications, .notificationsAnswered(true)), (.askingNotifications, .notificationsAnswered(true)),
             (.notificationsOff, .notificationsAnswered(true)): .practiceOffer
        case (.notifications, .notificationsAnswered(false)), (.askingNotifications, .notificationsAnswered(false)): .notificationsOff
        case (.notificationsOff, .continueWithoutNotifications): .practiceOffer
        case let (.practiceOffer, .sendPractice(id)), let (.practiceResult, .sendPractice(id)), let (.practiceNotArrived, .sendPractice(id)),
             let (.practiceMacUnreachable, .sendPractice(id)):
            .practiceWaiting(id: id, arrived: false)
        case let (.practiceWaiting(id, false), .practiceMacUnreachable), let (.settingUpNotifications(id), .practiceMacUnreachable):
            .practiceMacUnreachable(id: id)
        case let (.practiceWaiting(_, arrived), .practiceSent(id)): .practiceWaiting(id: id, arrived: arrived)
        case let (.settingUpNotifications, .practiceSent(id)): .settingUpNotifications(id: id)
        case let (.practiceNotArrived, .practiceSent(id)): .practiceNotArrived(id: id)
        case let (.practiceWaiting(id, false), .practiceArrived(pushExpected)):
            pushExpected ? .practiceWaiting(id: id, arrived: true) : .practice(id: id)
        case let (.settingUpNotifications(id), .practiceArrived), let (.practiceNotArrived(id), .practiceArrived),
             let (.practiceWaiting(id, _), .practiceTapped), let (.settingUpNotifications(id), .practiceTapped),
             let (.practiceNotArrived(id), .practiceTapped), let (.practiceWaiting(id, true), .practiceTimedOut):
            .practice(id: id)
        case let (.practiceWaiting(id, false), .practiceTimedOut(pushAddress)):
            pushAddress ? .practiceNotArrived(id: id) : .settingUpNotifications(id: id)
        case let (.practiceWaiting, .practiceEnded(outcome)), let (.settingUpNotifications, .practiceEnded(outcome)),
             let (.practiceNotArrived, .practiceEnded(outcome)), let (.practice, .practiceEnded(outcome)): .practiceResult(outcome)
        case let (.practiceOffer, .continueAfterPractice(watchToAdd)), let (.practiceResult, .continueAfterPractice(watchToAdd)),
             let (.practiceNotArrived, .continueAfterPractice(watchToAdd)), let (.settingUpNotifications, .continueAfterPractice(watchToAdd)),
             let (.practiceMacUnreachable, .continueAfterPractice(watchToAdd)):
            .readyOfferWatch(watchToAdd: watchToAdd)
        case (.readyOfferWatch(true), .addAppleWatch): .addWatch
        case (.readyOfferWatch, .done), (.addWatch, .done): .finished
        default: self
        }
    }

    /// Where first run picks up after the app was closed. What the look found is found again. A question
    /// iOS was asking did not outlive the app. A request to join, or a practice request, is picked up by
    /// the same request.
    public var restored: PhoneFirstRun {
        switch self {
        case .searching, .trouble, .foundMac: .start
        case .askingNotifications: .notifications
        case let .practiceWaiting(id, _), let .settingUpNotifications(id), let .practiceNotArrived(id), let .practice(id):
            .practiceWaiting(id: id, arrived: false)
        default: self
        }
    }

    /// The iPhone asks the Mac to join only here, after Connect.
    public var mayJoin: Bool {
        if case .waitingForMac = self { true } else { false }
    }

    /// The look for the Mac's join card runs before Connect, and while a refusal or expiry is on screen.
    public var looksForMac: Bool {
        switch self {
        case .searching, .trouble, .foundMac, .waitingForMac: true
        default: false
        }
    }

    /// The practice request first run is waiting on or showing.
    public var practiceID: String? {
        switch self {
        case let .practiceWaiting(id, _), let .settingUpNotifications(id), let .practiceNotArrived(id), let .practice(id): id
        default: nil
        }
    }

    /// A new practice request's id: 32 hex digits, chosen by the asker.
    public static func newPracticeID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// How a practice request ended, for the screen that stays up after it.
public enum PhonePracticeOutcome: Hashable, Sendable, Codable {
    case approved, denied, noAnswer
}

extension AccessRequest {
    /// The practice request id before joining, when it never leaves this iPhone.
    public static let localPracticeID = "practice"

    /// A practice request: it names no computer, and carries the practice words.
    public var isPractice: Bool { agent.machine.isEmpty && agent.name == PhoneCopy.practiceAgent }

    /// The practice request in the real request's layout, with the board's words.
    public static func practice(id: String = localPracticeID, askedAt: Date = .now, until: Date = .now.addingTimeInterval(600)) -> AccessRequest {
        AccessRequest(id: id, login: RequestedLogin(site: PhoneCopy.practiceSite, account: PhoneCopy.practiceAccount),
                      agent: RequestingAgent(name: PhoneCopy.practiceAgent, machine: "", address: ""),
                      access: .login, agentReason: PhoneCopy.practiceReason, askedAt: askedAt, state: .waitingForYou(until: until))
    }
}
