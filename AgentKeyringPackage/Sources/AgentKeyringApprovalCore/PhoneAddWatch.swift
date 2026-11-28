// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// Adding Apple Watch, run from the iPhone, as one explicit state: from the end
// of first run or from Devices, the same flow. Face ID comes first, after the
// page says why; the confirmation is held, with its end shown, until Apple
// Watch asks to be added, and asked for again with its reason if it lapses.
// Nothing is decrypted until the Watch asks. Timers stay outside and arrive as
// events. docs/state-machines.md has the table.

import Foundation

public enum PhoneAddWatchEvent: Hashable, Sendable {
    /// What WatchConnectivity says, on opening and on Check Again.
    case checked(paired: Bool, installed: Bool)
    /// Face ID passed: held until this time.
    case confirmed(until: Date)
    /// The held confirmation ended: its deadline passed, or the context was lost.
    case confirmationLapsed
    case watchHasNoPasscode
    /// Try Again on the passcode page. `now`: to know whether the confirmation still holds.
    case tryAgain(now: Date)
    /// Apple Watch tapped Add: `total` copies to make.
    case watchAsked(total: Int)
    case encrypted(done: Int, total: Int)
    case copiesSent
    case copiesFailed(reason: String)
    case cancel
    case done
}

public enum PhoneAddWatch: Hashable, Sendable {
    /// No Apple Watch is paired with this iPhone.
    case notPaired
    /// Paired, but Agent Keyring is not on it: the steps to install it, Check Again.
    case watchAppMissing
    /// Why adding it needs Face ID, with Continue with Face ID.
    case faceIDFirst
    /// Confirmed with Face ID until `until`: "Now tap Add on your Apple Watch".
    case waitingForWatch(until: Date)
    /// The confirmation lapsed, or iOS closed the app: Continue with Face ID again, with its reason.
    case faceIDExpired
    /// Apple Watch has no passcode, so it cannot keep its keys. `until`: the confirmation still held.
    case watchNeedsPasscode(until: Date)
    /// Apple Watch asked: this iPhone encrypts a copy of each password for it.
    case encrypting(done: Int, total: Int)
    /// Apple Watch is listed but its copies did not reach the Mac: Try Again sends only the copies.
    case copiesFailed(reason: String)
    /// Added, with Done.
    case added
    /// Cancelled or done: the flow is over.
    case closed

    /// Where the flow opens, from what WatchConnectivity says.
    public static func initialFlow(paired: Bool, installed: Bool) -> PhoneAddWatch {
        !paired ? .notPaired : !installed ? .watchAppMissing : .faceIDFirst
    }

    /// How long a Face ID confirmation is held for Apple Watch to ask.
    public static let hold: TimeInterval = 600

    /// The next state. Each state lists every event: the ones it moves on, and the ones it ignores, so a
    /// late callback cannot reopen the flow, and a new state or event does not compile until every pair says
    /// what it does. Cancel always closes it.
    public func on(_ event: PhoneAddWatchEvent) -> PhoneAddWatch {
        switch self {
        case .notPaired, .watchAppMissing:
            switch event {
            case let .checked(paired, installed): .initialFlow(paired: paired, installed: installed)
            case .cancel: .closed
            case .confirmed, .confirmationLapsed, .watchHasNoPasscode, .tryAgain, .watchAsked, .encrypted, .copiesSent,
                 .copiesFailed, .done: self
            }
        case .faceIDFirst, .faceIDExpired:
            switch event {
            case let .confirmed(until): .waitingForWatch(until: until)
            case .copiesSent: .added
            case .cancel: .closed
            case .checked, .confirmationLapsed, .watchHasNoPasscode, .tryAgain, .watchAsked, .encrypted, .copiesFailed,
                 .done: self
            }
        case let .waitingForWatch(until):
            switch event {
            case .confirmationLapsed: .faceIDExpired
            case .watchHasNoPasscode: .watchNeedsPasscode(until: until)
            case let .watchAsked(total): .encrypting(done: 0, total: total)
            case .copiesSent: .added
            case .cancel: .closed
            case .checked, .confirmed, .tryAgain, .encrypted, .copiesFailed, .done: self
            }
        case let .watchNeedsPasscode(until):
            switch event {
            case .confirmationLapsed: .faceIDExpired
            case let .tryAgain(now): until > now ? .waitingForWatch(until: until) : .faceIDExpired
            case .cancel: .closed
            case .checked, .confirmed, .watchHasNoPasscode, .watchAsked, .encrypted, .copiesSent, .copiesFailed, .done: self
            }
        case .encrypting:
            switch event {
            case let .encrypted(done, total): .encrypting(done: done, total: total)
            case .copiesSent: .added
            case let .copiesFailed(reason): .copiesFailed(reason: reason)
            case .confirmationLapsed: .faceIDExpired
            case .cancel: .closed
            case .checked, .confirmed, .watchHasNoPasscode, .tryAgain, .watchAsked, .done: self
            }
        case .copiesFailed:
            switch event {
            case .copiesSent: .added
            case let .watchAsked(total): .encrypting(done: 0, total: total)
            case .confirmationLapsed: .faceIDExpired
            case .cancel: .closed
            case .checked, .confirmed, .watchHasNoPasscode, .tryAgain, .encrypted, .copiesFailed, .done: self
            }
        case .added:
            switch event {
            case .done: .closed
            case .cancel: .closed
            case .checked, .confirmed, .confirmationLapsed, .watchHasNoPasscode, .tryAgain, .watchAsked, .encrypted,
                 .copiesSent, .copiesFailed: self
            }
        case .closed:
            switch event {
            case .cancel: .closed
            case .checked, .confirmed, .confirmationLapsed, .watchHasNoPasscode, .tryAgain, .watchAsked, .encrypted,
                 .copiesSent, .copiesFailed, .done: self
            }
        }
    }

    /// The iPhone is waiting for Apple Watch to ask: the Watch offers Add only now.
    public var watchMayAsk: Bool {
        switch self {
        case .waitingForWatch, .watchNeedsPasscode: true
        case .notPaired, .watchAppMissing, .faceIDFirst, .faceIDExpired, .encrypting, .copiesFailed, .added, .closed: false
        }
    }
}

/// A tap in the Apple Watch flow, as the page sends it.
public enum PhoneAddWatchTap: Hashable, Sendable {
    case open, continueWithFaceID, checkAgain, tryAgain, cancel, done
}
