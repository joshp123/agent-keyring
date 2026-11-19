// Written by AI on 2026.11.19 by model claude opus 5.5.
//
// First run on the Mac, as the Paper board "First run" draws it: each picture
// is a state and each caption a transition (docs/state-machines.md, "Mac first
// run"). The state holds only which screen he is on and what he did there;
// facts the world owns (the passwords, whether the agents on this Mac are set
// up, whether Touch ID can be used, how far a copy from Passwords has got)
// stay where they live and are read alongside it.

import Foundation

public enum FirstRun: Codable, Equatable, Sendable {
    case welcome
    /// The practice request is beside the pointer.
    case practice
    /// He denied it, with these words (empty if none); Try Again sends another.
    case practiceDenied(reply: String)
    /// "Copy your passwords": how far the copy has got is `PasswordsCopy`, shared with the main window.
    case copyPasswords
    /// "Set up your agents": Continue waits until the agents on this Mac are set up.
    case setUpAgents(copied: Copied)
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
        case done
    }

    /// The next state; an event the board draws no arrow for leaves it as it
    /// is. `agentsSetUp`: the agents on this Mac are set up, which Continue needs.
    public func after(_ event: Event, agentsSetUp: Bool) -> FirstRun {
        switch (self, event) {
        case (.welcome, .getStarted): .practice
        case (.practice, .practicePassed): .copyPasswords
        case let (.practice, .practiceDenied(reply)): .practiceDenied(reply: reply)
        case (.practiceDenied, .tryAgain): .practice
        case let (.copyPasswords, .imported(count)): .setUpAgents(copied: .passwords(count))
        case (.copyPasswords, .useSample): .setUpAgents(copied: .sample)
        // His own passwords replace the sample.
        case let (.setUpAgents, .imported(count)): .setUpAgents(copied: .passwords(count))
        case (.setUpAgents, .copyOwn), (.ready, .copyOwn): .copyPasswords
        case (.setUpAgents, .continueOn) where agentsSetUp: .ready
        case (.ready, .done): .finished
        default: self
        }
    }
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
