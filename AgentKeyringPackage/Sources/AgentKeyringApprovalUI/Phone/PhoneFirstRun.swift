// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// First run on the iPhone as one explicit state (Paper, "First run and the
// app", board "iPhone and Apple Watch", iPhone first run). Each case is one picture on the board and each event one of its
// captions. The backend sends it events and does what the state asks; nothing
// else decides where first run stands. Timers stay outside and arrive as
// events. docs/state-machines.md has the table.

import Foundation

public enum PhoneFirstRun: Hashable, Sendable, Codable {
    /// What the app is and how it keeps passwords safe, with Add This iPhone. Nothing is asked of the
    /// Mac until he taps it. `practising`: the practice request is open over it.
    case welcome(practising: Bool)
    /// He tapped Add This iPhone: the iPhone looks for his Mac's invitation and asks to join. Saved, so
    /// leaving the app or relaunching it picks up the same request instead of starting again.
    case linking(PhoneWelcomeCard)
    /// "Turn on notifications", with Continue.
    case notifications
    /// iOS's own question is up.
    case askingNotifications
    case notificationsOff
    /// "Try a request on this iPhone", with Send Practice Request.
    case practiceOffer
    /// A practice request has been asked for. `id`: the relay's request, once it has answered, so a return
    /// to the app shows that one again; nil while the ask is in flight. `arrived`: it is here, and its
    /// notification waits for a tap.
    case practiceWaiting(id: String?, arrived: Bool)
    /// 30 seconds passed and Apple has given no push address: the practice request opens by itself when it arrives.
    case settingUpNotifications(id: String?)
    /// 30 seconds passed and nothing arrived, though Apple gave an address.
    case practiceNotArrived(id: String?)
    /// The practice request is open.
    case practice(id: String)
    /// The practice's result stays on screen, with Send Another and Continue.
    case practiceResult(PhonePracticeOutcome)
    /// "Add your Apple Watch", only when one is paired and not yet added.
    case addWatch
    /// First run is over: the app's tabs, Home first.
    case finished

    public enum Event: Hashable, Sendable {
        /// Add This iPhone.
        case addThisPhone
        /// The look for the Mac found nothing. `longWait`: for two minutes.
        case noMac(longWait: Bool)
        /// The Mac is set up but has no computer that stays on.
        case macWithoutComputer(mac: String?)
        case joinWaiting(mac: String?)
        case joinRefused(mac: String?)
        case askAgain
        case joined
        case tryPractice
        case closePractice
        case continueTapped
        case notificationsAnswered(allowed: Bool)
        case continueWithoutNotifications
        /// The relay has made the practice request asked for, with this id.
        case practiceSent(id: String)
        /// `pushExpected`: its notification will come, so it waits for a tap.
        case practiceArrived(pushExpected: Bool)
        case practiceTapped
        /// 30 seconds after asking. `pushAddress`: Apple has given one.
        case practiceTimedOut(pushAddress: Bool)
        case tryAgain
        /// Send Practice Request, or Send Another.
        case sendPractice
        case practiceEnded(PhonePracticeOutcome)
        /// Continue after the practice's result. `watchToAdd`: an Apple Watch is paired and not yet added.
        case continueAfterPractice(watchToAdd: Bool)
        /// Skip, or Apple Watch was added.
        case watchDone
        /// This iPhone was taken out of the list of devices.
        case removed
    }

    public static let start = PhoneFirstRun.welcome(practising: false)
    static let lookingForMac = PhoneFirstRun.linking(.startOnMac(longWait: false))

    /// The next state. A pair the table does not list leaves the state as it is,
    /// so a repeated tap or a late answer cannot move first run anywhere wrong.
    public func on(_ event: Event) -> PhoneFirstRun {
        switch (self, event) {
        case (_, .removed): .start
        case (.welcome(false), .addThisPhone): .lookingForMac
        case (.welcome(false), .tryPractice): .welcome(practising: true)
        case (.welcome(true), .closePractice): .welcome(practising: false)
        // The Mac refused: it stays refused until Ask Again, whatever the look finds.
        case (.linking(.denied), .noMac), (.linking(.denied), .macWithoutComputer), (.linking(.denied), .joinWaiting): self
        case (.linking(.denied), .askAgain): .lookingForMac
        case let (.linking, .noMac(longWait)): .linking(.startOnMac(longWait: longWait))
        case let (.linking, .macWithoutComputer(mac)): .linking(.addComputer(mac: mac))
        case let (.linking, .joinWaiting(mac)): .linking(.approveOnMac(mac: mac))
        case let (.linking, .joinRefused(mac)): .linking(.denied(mac: mac))
        case (.linking, .joined): .notifications
        case (.notifications, .continueTapped): .askingNotifications
        case (.notifications, .notificationsAnswered(true)), (.askingNotifications, .notificationsAnswered(true)),
             (.notificationsOff, .notificationsAnswered(true)): .practiceOffer
        case (.notifications, .notificationsAnswered(false)), (.askingNotifications, .notificationsAnswered(false)): .notificationsOff
        case (.notificationsOff, .continueWithoutNotifications): .practiceOffer
        case (.practiceOffer, .sendPractice), (.practiceResult, .sendPractice), (.practiceNotArrived, .tryAgain):
            .practiceWaiting(id: nil, arrived: false)
        case let (.practiceWaiting(nil, arrived), .practiceSent(id)): .practiceWaiting(id: id, arrived: arrived)
        case let (.settingUpNotifications(nil), .practiceSent(id)): .settingUpNotifications(id: id)
        case let (.practiceNotArrived(nil), .practiceSent(id)): .practiceNotArrived(id: id)
        case let (.practiceWaiting(id?, false), .practiceArrived(pushExpected)):
            pushExpected ? .practiceWaiting(id: id, arrived: true) : .practice(id: id)
        case let (.settingUpNotifications(id?), .practiceArrived), let (.practiceNotArrived(id?), .practiceArrived),
             let (.practiceWaiting(id?, _), .practiceTapped), let (.settingUpNotifications(id?), .practiceTapped),
             let (.practiceNotArrived(id?), .practiceTapped), let (.practiceWaiting(id?, true), .practiceTimedOut):
            .practice(id: id)
        case let (.practiceWaiting(id, false), .practiceTimedOut(pushAddress)):
            pushAddress ? .practiceNotArrived(id: id) : .settingUpNotifications(id: id)
        case let (.practiceWaiting, .practiceEnded(outcome)), let (.settingUpNotifications, .practiceEnded(outcome)),
             let (.practiceNotArrived, .practiceEnded(outcome)), let (.practice, .practiceEnded(outcome)): .practiceResult(outcome)
        case let (.practiceResult, .continueAfterPractice(watchToAdd)): watchToAdd ? .addWatch : .finished
        case (.addWatch, .watchDone): .finished
        default: self
        }
    }

    /// Where first run picks up after the app was closed. A question iOS was asking did not outlive the
    /// app. A request to join, or a practice request the relay has made, is picked up by the same request;
    /// a practice ask the relay never answered is offered again.
    public var restored: PhoneFirstRun {
        switch self {
        case .welcome: .start
        case .linking(.denied): self
        case .linking: .lookingForMac
        case .askingNotifications: .notifications
        case let .practiceWaiting(id?, _), let .settingUpNotifications(id?), let .practiceNotArrived(id?), let .practice(id):
            .practiceWaiting(id: id, arrived: false)
        case .practiceWaiting, .settingUpNotifications, .practiceNotArrived: .practiceOffer
        default: self
        }
    }

    /// The look for the Mac may ask to join: only after Add This iPhone, and not once the Mac refused, until Ask Again.
    public var mayJoin: Bool {
        guard case let .linking(card) = self else { return false }
        if case .denied = card { return false }
        return true
    }

    /// The practice request first run is waiting on or showing, once the relay has made it.
    public var practiceID: String? {
        switch self {
        case let .practiceWaiting(id, _), let .settingUpNotifications(id), let .practiceNotArrived(id): id
        case let .practice(id): id
        default: nil
        }
    }

    /// A practice request has been asked for and the relay has not yet said which.
    public var practiceAskInFlight: Bool {
        switch self {
        case .practiceWaiting(nil, _), .settingUpNotifications(nil), .practiceNotArrived(nil): true
        default: false
        }
    }
}

/// How a practice request ended, for the screen that stays up after it.
public enum PhonePracticeOutcome: Hashable, Sendable, Codable {
    case approved, denied, noAnswer
}

/// Where linking stands, under the welcome text. `mac`: the Mac's name, when known.
public enum PhoneWelcomeCard: Hashable, Sendable, Codable {
    case startOnMac(longWait: Bool)
    case addComputer(mac: String?)
    case approveOnMac(mac: String?)
    case denied(mac: String?)
}

extension AccessRequest {
    /// The practice request id before joining, when it never leaves this iPhone.
    public static let localPracticeID = "practice"

    /// The practice request in the real request's layout, with the board's words.
    public static func practice(id: String = localPracticeID, askedAt: Date = .now, until: Date = .now.addingTimeInterval(600)) -> AccessRequest {
        AccessRequest(id: id, login: RequestedLogin(site: PhoneCopy.practiceSite, account: PhoneCopy.practiceAccount),
                      agent: RequestingAgent(name: PhoneCopy.practiceAgent, machine: "", address: ""),
                      access: .login, agentReason: PhoneCopy.practiceReason, askedAt: askedAt, state: .waitingForYou(until: until))
    }
}
