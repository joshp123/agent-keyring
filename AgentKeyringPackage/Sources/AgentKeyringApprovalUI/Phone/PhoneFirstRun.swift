// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// First run on the iPhone as one explicit state (Paper, "First run", iPhone
// row). Each case is one picture on the board and each event one of its
// captions. The backend sends it events and does what the state asks; nothing
// else decides where first run stands. Timers stay outside and arrive as
// events. docs/state-machines.md has the table.

import Foundation

public enum PhoneFirstRun: Hashable, Sendable, Codable {
    /// Not joined: what the app is, with a card for where setup stands.
    /// `practising`: the practice request is open over it.
    case welcome(PhoneWelcomeCard, practising: Bool)
    /// "Answer requests from your Lock Screen", with Continue.
    case notifications
    /// iOS's own question is up.
    case askingNotifications
    case notificationsOff
    /// The relay has been asked for the practice request. `arrived`: it is
    /// here, and its notification waits for a tap.
    case practiceWaiting(arrived: Bool)
    /// 30 seconds passed and Apple has given no push address: the practice
    /// request opens by itself when it arrives.
    case settingUpNotifications
    /// 30 seconds passed and nothing arrived, though Apple gave an address.
    case practiceNotArrived
    /// The practice request is open.
    case practice
    case ready
    /// He tapped Done: the app's tabs.
    case finished

    public enum Event: Hashable, Sendable {
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
        /// `pushExpected`: its notification will come, so it waits for a tap.
        case practiceArrived(pushExpected: Bool)
        case practiceTapped
        /// 30 seconds after asking. `pushAddress`: Apple has given one.
        case practiceTimedOut(pushAddress: Bool)
        case tryAgain
        /// Approved, denied or unanswered: the board draws only Ready after it.
        case practiceEnded
        case done
        /// This iPhone was taken out of the list of devices.
        case removed
    }

    public static let start = PhoneFirstRun.welcome(.startOnMac(longWait: false), practising: false)

    /// The next state. A pair the table does not list leaves the state as it is,
    /// so a repeated tap or a late answer cannot move first run anywhere wrong.
    public func on(_ event: Event) -> PhoneFirstRun {
        switch (self, event) {
        case (_, .removed): .start
        // The Mac refused: it stays refused until Ask Again, whatever the look finds.
        case (.welcome(.denied, _), .noMac), (.welcome(.denied, _), .macWithoutComputer), (.welcome(.denied, _), .joinWaiting): self
        case let (.welcome(.denied, practising), .askAgain): .welcome(.startOnMac(longWait: false), practising: practising)
        case let (.welcome(_, practising), .noMac(longWait)): .welcome(.startOnMac(longWait: longWait), practising: practising)
        case let (.welcome(_, practising), .macWithoutComputer(mac)): .welcome(.addComputer(mac: mac), practising: practising)
        case let (.welcome(_, practising), .joinWaiting(mac)): .welcome(.approveOnMac(mac: mac), practising: practising)
        case let (.welcome(_, practising), .joinRefused(mac)): .welcome(.denied(mac: mac), practising: practising)
        case (.welcome, .joined): .notifications
        case let (.welcome(card, false), .tryPractice): .welcome(card, practising: true)
        case let (.welcome(card, true), .closePractice): .welcome(card, practising: false)
        case (.notifications, .continueTapped): .askingNotifications
        case (.notifications, .notificationsAnswered(true)), (.askingNotifications, .notificationsAnswered(true)),
             (.notificationsOff, .notificationsAnswered(true)): .practiceWaiting(arrived: false)
        case (.notifications, .notificationsAnswered(false)), (.askingNotifications, .notificationsAnswered(false)): .notificationsOff
        case (.notificationsOff, .continueWithoutNotifications): .practiceWaiting(arrived: false)
        case let (.practiceWaiting(false), .practiceArrived(pushExpected)): pushExpected ? .practiceWaiting(arrived: true) : .practice
        case (.settingUpNotifications, .practiceArrived), (.practiceNotArrived, .practiceArrived): .practice
        case (.practiceWaiting, .practiceTapped), (.settingUpNotifications, .practiceTapped), (.practiceNotArrived, .practiceTapped): .practice
        case (.practiceWaiting(true), .practiceTimedOut): .practice
        case let (.practiceWaiting(false), .practiceTimedOut(pushAddress)): pushAddress ? .practiceNotArrived : .settingUpNotifications
        case (.practiceNotArrived, .tryAgain): .practiceWaiting(arrived: false)
        case (.practiceWaiting, .practiceEnded), (.settingUpNotifications, .practiceEnded), (.practiceNotArrived, .practiceEnded),
             (.practice, .practiceEnded): .ready
        case (.ready, .done): .finished
        default: self
        }
    }

    /// Where first run picks up after the app was closed: a question iOS was
    /// asking, or a practice request in flight, did not outlive the app.
    public var restored: PhoneFirstRun {
        switch self {
        case .welcome: .start
        case .askingNotifications: .notifications
        case .practiceWaiting, .settingUpNotifications, .practiceNotArrived, .practice: .practiceWaiting(arrived: false)
        default: self
        }
    }

    /// The look for the Mac may ask to join: not once the Mac refused, until Ask Again.
    public var mayJoin: Bool {
        guard case let .welcome(card, _) = self else { return false }
        if case .denied = card { return false }
        return true
    }

    /// The relay should be sending this iPhone a practice request.
    public var wantsPractice: Bool {
        switch self {
        case .practiceWaiting, .settingUpNotifications, .practice: true
        default: false
        }
    }
}

/// The card under "Agent Keyring" on the first screen. `mac`: the Mac's name, when known.
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
