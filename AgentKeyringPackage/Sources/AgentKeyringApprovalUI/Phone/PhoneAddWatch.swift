// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// Adding Apple Watch, run from the iPhone, as one explicit state: from the end
// of first run or from Devices, the same flow. Face ID comes first, after the
// page says why; the confirmation is held, with its end shown, until Apple
// Watch asks to be added, and asked for again with its reason if it lapses.
// Nothing is decrypted until the Watch asks. Timers stay outside and arrive as
// events. docs/state-machines.md has the table.

import Foundation

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

    public enum Event: Hashable, Sendable {
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

    /// Where the flow opens, from what WatchConnectivity says.
    public static func start(paired: Bool, installed: Bool) -> PhoneAddWatch {
        !paired ? .notPaired : !installed ? .watchAppMissing : .faceIDFirst
    }

    /// How long a Face ID confirmation is held for Apple Watch to ask.
    public static let hold: TimeInterval = 600

    public func on(_ event: Event) -> PhoneAddWatch {
        switch (self, event) {
        case (_, .cancel), (.added, .done): .closed
        case let (.notPaired, .checked(paired, installed)), let (.watchAppMissing, .checked(paired, installed)):
            .start(paired: paired, installed: installed)
        case let (.faceIDFirst, .confirmed(until)), let (.faceIDExpired, .confirmed(until)): .waitingForWatch(until: until)
        case (.waitingForWatch, .confirmationLapsed), (.watchNeedsPasscode, .confirmationLapsed): .faceIDExpired
        case let (.waitingForWatch(until), .watchHasNoPasscode): .watchNeedsPasscode(until: until)
        case let (.watchNeedsPasscode(until), .tryAgain(now)): until > now ? .waitingForWatch(until: until) : .faceIDExpired
        case let (.waitingForWatch, .watchAsked(total)): .encrypting(done: 0, total: total)
        case let (.encrypting, .encrypted(done, total)): .encrypting(done: done, total: total)
        case (.encrypting, .copiesSent): .added
        case let (.encrypting, .copiesFailed(reason)): .copiesFailed(reason: reason)
        case let (.copiesFailed, .watchAsked(total)): .encrypting(done: 0, total: total)
        case (.copiesFailed, .confirmationLapsed), (.encrypting, .confirmationLapsed): .faceIDExpired
        default: self
        }
    }

    /// The iPhone is waiting for Apple Watch to ask: the Watch offers Add only now.
    public var watchMayAsk: Bool {
        switch self {
        case .waitingForWatch, .watchNeedsPasscode: true
        default: false
        }
    }
}

/// A tap in the Apple Watch flow, as the page sends it.
public enum PhoneAddWatchTap: Hashable, Sendable {
    case open, continueWithFaceID, checkAgain, tryAgain, cancel, done
}
