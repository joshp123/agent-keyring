// Written by AI on 2026.11.19 by model claude opus 5.5.
//
// First run on the Mac, as the Paper board "First run" draws it: each picture
// is a state and each caption a transition (docs/state-machines.md, "Mac first
// run"). The state holds only which screen he is on and what he did there;
// facts the world owns (the passwords, the computers, whether Touch ID can be
// used) stay where they live and are read alongside it.

import Foundation

public enum FirstRun: Codable, Equatable, Sendable {
    case welcome
    /// The practice request is beside the pointer.
    case practice
    /// He denied it, with these words (empty if none); Try Again sends another.
    case practiceDenied(reply: String)
    case copyPasswords(Export)
    case copying
    case setUpAgents(copied: Copied, messageCopied: Bool)
    /// The agents on this Mac are set up; each computer they add is a request he approves.
    case computers
    case ready
    /// He chose Do This Later on "Set up your agents".
    case almostReady
    case finished

    public enum Export: Codable, Equatable, Sendable {
        case notOpened
        /// After Open Passwords.
        case waiting
        /// Five minutes after Open Passwords, nothing has arrived.
        case noneArrived
    }

    public enum Copied: Codable, Equatable, Sendable {
        case passwords(Int)
        case sample
    }

    public enum Event: Equatable, Sendable {
        case getStarted
        case practicePassed
        case practiceDenied(reply: String)
        case tryAgain
        case openPasswords
        case exportTimedOut
        case importStarted
        case imported(count: Int)
        case importFailed
        case useSample
        case copyMessage
        /// `agent-keyring install` ran on this Mac.
        case agentsSetUp
        case continueOn
        case doThisLater
        case done
    }

    /// The next state; an event the board draws no arrow for leaves it as it is.
    public func after(_ event: Event) -> FirstRun {
        switch (self, event) {
        case (.welcome, .getStarted): .practice
        case (.practice, .practicePassed): .copyPasswords(.notOpened)
        case let (.practice, .practiceDenied(reply)): .practiceDenied(reply: reply)
        case (.practiceDenied, .tryAgain): .practice
        case (.copyPasswords, .openPasswords): .copyPasswords(.waiting)
        case (.copyPasswords(.waiting), .exportTimedOut): .copyPasswords(.noneArrived)
        case (.copyPasswords, .importStarted): .copying
        case let (.copying, .imported(count)): .setUpAgents(copied: .passwords(count), messageCopied: false)
        case (.copying, .importFailed): .copyPasswords(.notOpened)
        case (.copyPasswords, .useSample): .setUpAgents(copied: .sample, messageCopied: false)
        // His own passwords replace the sample.
        case let (.setUpAgents(_, copiedMessage), .imported(count)): .setUpAgents(copied: .passwords(count), messageCopied: copiedMessage)
        case let (.setUpAgents(copied, _), .copyMessage): .setUpAgents(copied: copied, messageCopied: true)
        case (.setUpAgents, .agentsSetUp): .computers
        case (.setUpAgents, .doThisLater): .almostReady
        case (.computers, .continueOn): .ready
        case (.ready, .done), (.almostReady, .done): .finished
        default: self
        }
    }

    /// An agent that set this Mac up before he reached "Set up your agents"
    /// has already done what that step waits for.
    public func settled(agentsSetUp: Bool) -> FirstRun {
        if case .setUpAgents = self, agentsSetUp { return .computers }
        return self
    }

    /// Where a restart resumes: a copy or a wait the app no longer runs starts again.
    public var resumed: FirstRun {
        switch self {
        case .copying, .copyPasswords: .copyPasswords(.notOpened)
        default: self
        }
    }
}
