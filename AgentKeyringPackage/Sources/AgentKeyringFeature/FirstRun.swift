// Written by AI on 2026.11.19 by model claude opus 5.5; rebuilt on 2026.11.20
// from the Paper board "Mac", ten steps, one window each.
//
// First run on the Mac: each window on the board is a state and each button a
// transition (docs/state-machines.md, "Mac first run"). The state holds only
// which window he is on and what he did there; facts the world owns (the
// passwords, whether Touch ID can be used, how far a copy from Passwords has
// got, which devices and computers have joined, the last practice result on
// each device) stay where they live and are read alongside it.

import Foundation

public enum FirstRun: Codable, Equatable, Sendable {
    case welcome
    /// The practice request is beside the window.
    case practice
    /// He denied it, with these words (empty if none); Try Again sends another.
    case practiceDenied(reply: String)
    /// "Copy your passwords": how far the copy has got is `PasswordsCopy`, shared with the main window.
    case copyPasswords
    /// "Tell your agents about Agent Keyring": the note he gives them, and "Try it now".
    case tellAgents(copied: Copied)
    /// "Approve from your iPhone and Apple Watch": a computer of his that stays on.
    case stayingOn
    case addPhone
    case addWatch
    case addComputers
    /// "Try a request on each device".
    case tryDevices
    case ready
    case finished

    public enum Copied: Codable, Equatable, Sendable {
        case passwords(Int)
        case sample
    }

    public enum Event: Equatable, Sendable {
        case getStarted
        case practicePassed
        case practiceDenied(reply: String)
        case tryAgain
        case imported(count: Int)
        case useSample
        /// From the sample, back to "Copy your passwords".
        case copyOwn
        case continueOn
        /// Touch ID approved the computer that stays on.
        case connected
        /// "Use This Mac Alone": no iPhone, Apple Watch or other computers for now.
        case useThisMacAlone
        case skip
        case done
    }

    /// The next state; an event the board draws no arrow for leaves it as it
    /// is. `joined`: this Mac already reaches a computer that stays on, so
    /// that window is passed over.
    public func after(_ event: Event, joined: Bool = false) -> FirstRun {
        switch (self, event) {
        case (.welcome, .getStarted): .practice
        case (.practice, .practicePassed): .copyPasswords
        case let (.practice, .practiceDenied(reply)): .practiceDenied(reply: reply)
        case (.practiceDenied, .tryAgain): .practice
        case let (.copyPasswords, .imported(count)): .tellAgents(copied: .passwords(count))
        case (.copyPasswords, .useSample): .tellAgents(copied: .sample)
        // His own passwords replace the sample.
        case let (.tellAgents, .imported(count)): .tellAgents(copied: .passwords(count))
        case (.tellAgents, .copyOwn), (.ready, .copyOwn): .copyPasswords
        case (.tellAgents, .continueOn): joined ? .addPhone : .stayingOn
        case (.stayingOn, .connected): .addPhone
        case (.stayingOn, .useThisMacAlone): .tryDevices
        case (.addPhone, .continueOn): .addWatch
        case (.addPhone, .skip), (.addWatch, .continueOn), (.addWatch, .skip): .addComputers
        case (.addComputers, .continueOn): .tryDevices
        case (.tryDevices, .continueOn): .ready
        case (.ready, .done): .finished
        default: self
        }
    }
}

/// The last practice request sent to one device: shown on "Try a request on
/// each device" and in Devices, by device key. Not saved.
public enum PracticeResult: Equatable, Sendable {
    case sent
    case approved(at: Date)
    case denied(at: Date, reply: String)
    case unanswered
    case failed(String)
}

/// "Copy your passwords", one for first run and the main window's Copy from
/// Passwords alike. The app holds it as an optional: nil when no copy is open,
/// which first run draws as the three steps. Not saved: after a restart the
/// copy starts again.
public enum PasswordsCopy: Equatable, Sendable {
    /// The three steps, before Open Passwords.
    case steps
    /// After Open Passwords.
    case waiting
    /// Five minutes after Open Passwords, nothing has arrived.
    case noneArrived
    /// "Agent Keyring isn't in the list?": macOS's AutoFill setting decides
    /// which apps Passwords can export to. `asking`: macOS's dialog is up, or
    /// was in the last 10 seconds, when it would ignore another request.
    case allowExport(asking: Bool)
    /// The passwords are arriving and being sealed.
    case copying
}
