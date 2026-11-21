// Written by AI on 2026.11.19 by model claude opus 5.5; rebuilt on 2026.11.21
// by the same model for the four local steps, with no journey and no device choice.
//
// First run on the Mac: one saved value, each window a state and each button
// a transition (docs/state-machines.md, "Mac first run"). Facts the world owns
// (the passwords, whether Touch ID can be used, how far a copy from Passwords
// has got, which devices have joined) stay where they live and are read beside it.

import Foundation

public struct FirstRun: Codable, Equatable, Sendable {
    /// The window he is on.
    public var step: Step
    /// The practice request on step 1. Kept when he moves on, so Back finds his answer.
    public var practice: Practice

    public enum Step: Codable, Equatable, Sendable {
        case welcome
        /// Step 1 of 4: Try a password request.
        case practice
        /// Step 2 of 4: Copy your passwords. How far a copy has got is `PasswordsCopy`.
        case copy
        /// Step 3 of 4: Connect an agent.
        case connectAgent(ConnectAgent)
        /// Step 4 of 4: Ready, with the other devices to add.
        case ready
        /// He clicked Show Passwords: the window is Passwords and Devices.
        case finished
    }

    public enum Practice: Codable, Equatable, Sendable {
        case notSent
        /// The practice panel is beside the window, for this request only.
        case waiting(id: UUID)
        case approved
        /// His words, empty if none.
        case denied(reply: String)

        public var isAnswered: Bool {
            switch self {
            case .approved, .denied: true
            case .notSent, .waiting: false
            }
        }
    }

    /// The outcome of the first request from an agent on this Mac, after he reached this step.
    public enum ConnectAgent: Codable, Equatable, Sendable {
        case notTried
        case worked(agent: String)
        case denied(agent: String)
    }

    public enum Event: Equatable, Sendable {
        case getStarted
        case back
        case continueOn
        case sendPractice(id: UUID)
        case practiceApproved(id: UUID)
        case practiceDenied(id: UUID, reply: String)
        case useTestPasswordOnly
        /// An agent on this Mac had its request answered.
        case agentAnswered(agent: String, approved: Bool)
        case skipTest
        case showPasswords
    }

    public init(step: Step, practice: Practice = .notSent) {
        self.step = step
        self.practice = practice
    }

    public static let welcome = FirstRun(step: .welcome)
    public static let finished = FirstRun(step: .finished)

    /// The next state; an event with no arrow leaves it as it is.
    /// Continue on Copy is offered only once his passwords are copied; the window checks that fact.
    public func after(_ event: Event) -> FirstRun {
        var next = self
        switch (step, event) {
        case (.welcome, .getStarted):
            next.step = .practice
        case (.practice, .back):
            next = .welcome
        case let (.practice, .sendPractice(id)) where !isWaiting:
            next.practice = .waiting(id: id)
        case let (.practice, .practiceApproved(id)) where practice == .waiting(id: id):
            next.practice = .approved
        case let (.practice, .practiceDenied(id, reply)) where practice == .waiting(id: id):
            next.practice = .denied(reply: reply)
        case (.practice, .continueOn) where practice.isAnswered:
            next.step = .copy
        case (.copy, .back):
            next.step = .practice
        case (.copy, .continueOn), (.copy, .useTestPasswordOnly):
            next.step = .connectAgent(.notTried)
        case let (.connectAgent(.notTried), .agentAnswered(agent, approved)):
            next.step = .connectAgent(approved ? .worked(agent: agent) : .denied(agent: agent))
        case (.connectAgent, .back):
            next.step = .copy
        case (.connectAgent(.notTried), .skipTest), (.connectAgent(.worked), .continueOn), (.connectAgent(.denied), .continueOn):
            next.step = .ready
        case (.ready, .back):
            next.step = .connectAgent(.notTried)
        case (.ready, .showPasswords):
            next.step = .finished
        default:
            break
        }
        return next
    }

    private var isWaiting: Bool { if case .waiting = practice { true } else { false } }

    /// The practice request waiting beside the window, if any.
    public var waitingPractice: UUID? {
        guard step == .practice, case let .waiting(id) = practice else { return nil }
        return id
    }

    /// As saved, resumed after a restart: a practice request left waiting is not sent again by itself.
    var restored: FirstRun {
        guard case .waiting = practice else { return self }
        return FirstRun(step: step, practice: .notSent)
    }
}

/// The last practice request sent to one device: shown in Devices, by device key. Not saved.
public enum PracticeResult: Equatable, Sendable {
    /// Asked for; not yet with Apple.
    case sent
    /// Apple has the notification.
    case withApple(at: Date)
    /// The device said it arrived.
    case arrived(at: Date, on: String)
    case approved(at: Date)
    case denied(at: Date, reply: String)
    case unanswered
    case failed(String)
}

/// "Copy your passwords", one for first run and the main window's Copy Again
/// alike. The app holds it as an optional: nil when no copy is open, which
/// first run draws as the guide. Not saved: after a restart the copy starts again.
public enum PasswordsCopy: Equatable, Sendable {
    /// The guide, before Open Passwords.
    case steps
    /// After Open Passwords.
    case waiting
    /// Five minutes after Open Passwords, nothing has arrived.
    case noneArrived
    /// "Agent Keyring isn't in the list?": the sheet that sends him to AutoFill
    /// settings. It checks again each time the app comes to the front, and
    /// closes by itself once Agent Keyring is turned on there.
    case allowExport
    /// The passwords are arriving and being sealed.
    case copying
}

/// What a copy from Passwords changed since the list the other devices last
/// received: added, changed (its last-changed date moved) and removed.
public struct PasswordChanges: Equatable, Sendable {
    public var added: Int
    public var changed: Int
    public var removed: Int
    public var total: Int { added + changed + removed }

    public init(added: Int = 0, changed: Int = 0, removed: Int = 0) {
        self.added = added
        self.changed = changed
        self.removed = removed
    }

    /// `sent` and `now`: each password's id and its last-changed date. A date
    /// unknown in the record (it was made before dates were kept) never counts as changed.
    public init(sent: [String: Date?], now: [String: Date?]) {
        added = now.keys.filter { sent[$0] == nil }.count
        removed = sent.keys.filter { now[$0] == nil }.count
        changed = now.filter { id, date in
            guard let recorded = sent[id], let recorded else { return false }
            return date != recorded
        }.count
    }
}
