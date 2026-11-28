// Written by AI on 2026.11.19 by model claude opus 5.5; rebuilt on 2026.11.21
// by the same model for the four local steps, with no journey and no device choice.
//
// First run on the Mac: one saved value, each window a state and each button
// a transition (docs/state-machines.md, "Mac first run"). Facts the world owns
// (the passwords, whether Touch ID can be used, how far a copy from Passwords
// has got, which devices have joined) stay where they live and are read beside it.

#if os(macOS)
import AgentKeyringProtocol
import Foundation

public enum MacFirstRunEvent: Equatable, Sendable {
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

public enum MacFirstRunStep: Equatable, Sendable {
    case welcome
    /// Step 1 of 5: Try a password request.
    case practice
    /// Step 2 of 5: Privacy.
    case privacy
    /// Step 3 of 5: Add passwords. How far a copy has got is `SelectiveImportSession`.
    case copy
    /// Step 4 of 5: Connect an agent.
    case connectAgent(FirstAgentRequestOutcome)
    /// Step 5 of 5: Ready, with the other devices to add.
    case ready
    /// He clicked Show Passwords: the window is Passwords and Devices.
    case finished
}

/// The outcome of the first request from an agent on this Mac, after he reached this step.
public enum FirstAgentRequestOutcome: Equatable, Sendable {
    case notTried
    case worked(agent: String)
    case denied(agent: String)
}

public enum MacFirstRunPracticeState: Equatable, Sendable {
    case notSent
    /// The practice panel is beside the window, for this request only.
    case waiting(id: UUID)
    case approved
    /// His words, empty if none.
    case denied(reply: String)

    var isAnswered: Bool {
        switch self {
        case .approved, .denied: true
        case .notSent, .waiting: false
        }
    }
}

public struct MacFirstRunFlow: Equatable, Sendable {
    public static let protobufMagic = Data("AKRFR02".utf8)

    private enum CodecError: Error {
        case invalidMagic
        case invalidStep
        case invalidPractice
        case invalidConnectAgent
    }
    /// The window he is on.
    public var step: MacFirstRunStep
    /// The practice request on step 1. Kept when he moves on, so Back finds his answer.
    public var practice: MacFirstRunPracticeState

    public init(step: MacFirstRunStep, practice: MacFirstRunPracticeState = .notSent) {
        self.step = step
        self.practice = practice
    }

    public static let welcome = MacFirstRunFlow(step: .welcome)
    public static let finished = MacFirstRunFlow(step: .finished)

    /// The next state; an event with no arrow leaves it as it is. Every step
    /// names every event, so a new step or event does not compile until it is
    /// given its arrows. Continue on Copy is offered only once his passwords
    /// are copied; the window checks that fact.
    public func after(_ event: MacFirstRunEvent) -> MacFirstRunFlow {
        var next = self
        switch step {
        case .welcome:
            switch event {
            case .getStarted: next.step = .practice
            case .back, .continueOn, .sendPractice, .practiceApproved, .practiceDenied, .useTestPasswordOnly,
                 .agentAnswered, .skipTest, .showPasswords: break
            }
        case .practice:
            next = afterPractice(event)
        case .privacy:
            switch event {
            case .back: next.step = .practice
            case .continueOn: next.step = .copy
            case .getStarted, .sendPractice, .practiceApproved, .practiceDenied, .useTestPasswordOnly,
                 .agentAnswered, .skipTest, .showPasswords: break
            }
        case .copy:
            switch event {
            case .back: next.step = .privacy
            case .continueOn, .useTestPasswordOnly: next.step = .connectAgent(.notTried)
            case .getStarted, .sendPractice, .practiceApproved, .practiceDenied, .agentAnswered,
                 .skipTest, .showPasswords: break
            }
        case let .connectAgent(outcome):
            next.step = Self.afterConnectAgent(outcome, event)
        case .ready:
            switch event {
            case .back: next.step = .connectAgent(.notTried)
            case .showPasswords: next.step = .finished
            case .getStarted, .continueOn, .sendPractice, .practiceApproved, .practiceDenied,
                 .useTestPasswordOnly, .agentAnswered, .skipTest: break
            }
        case .finished:
            switch event {
            case .getStarted, .back, .continueOn, .sendPractice, .practiceApproved, .practiceDenied,
                 .useTestPasswordOnly, .agentAnswered, .skipTest, .showPasswords: break
            }
        }
        return next
    }

    /// Step 1: one practice request at a time; an answer counts only for the request waiting.
    private func afterPractice(_ event: MacFirstRunEvent) -> MacFirstRunFlow {
        var next = self
        switch event {
        case .back:
            next = .welcome
        case let .sendPractice(id):
            if !isWaiting { next.practice = .waiting(id: id) }
        case let .practiceApproved(id):
            if practice == .waiting(id: id) { next.practice = .approved }
        case let .practiceDenied(id, reply):
            if practice == .waiting(id: id) { next.practice = .denied(reply: reply) }
        case .continueOn:
            if practice.isAnswered { next.step = .privacy }
        case .getStarted, .useTestPasswordOnly, .agentAnswered, .skipTest, .showPasswords:
            break
        }
        return next
    }

    /// Step 4: the first answer to an agent on this Mac is kept until he goes back.
    private static func afterConnectAgent(_ outcome: FirstAgentRequestOutcome, _ event: MacFirstRunEvent) -> MacFirstRunStep {
        let here = MacFirstRunStep.connectAgent(outcome)
        switch event {
        case .back:
            return .copy
        case let .agentAnswered(agent, approved):
            switch outcome {
            case .notTried: return .connectAgent(approved ? .worked(agent: agent) : .denied(agent: agent))
            case .worked, .denied: return here
            }
        case .skipTest:
            switch outcome {
            case .notTried: return .ready
            case .worked, .denied: return here
            }
        case .continueOn:
            switch outcome {
            case .notTried: return here
            case .worked, .denied: return .ready
            }
        case .getStarted, .sendPractice, .practiceApproved, .practiceDenied, .useTestPasswordOnly, .showPasswords:
            return here
        }
    }

    private var isWaiting: Bool { if case .waiting = practice { true } else { false } }

    /// The practice request waiting beside the window, if any.
    public var waitingPractice: UUID? {
        guard step == .practice, case let .waiting(id) = practice else { return nil }
        return id
    }

    /// As saved, resumed after a restart: a practice request left waiting is not sent again by itself.
    var restored: MacFirstRunFlow {
        guard case .waiting = practice else { return self }
        return MacFirstRunFlow(step: step, practice: .notSent)
    }

    public func encodeProtobuf() throws -> Data {
        Self.protobufMagic + (try storedProto().serializedData())
    }

    public static func decodeProtobuf(_ data: Data) throws -> MacFirstRunFlow {
        guard data.starts(with: protobufMagic) else { throw CodecError.invalidMagic }
        return try MacFirstRunFlow(storedProto: Agentkeyring_V2_StoredMacFirstRun(serializedBytes: Data(data.dropFirst(protobufMagic.count))))
    }

    init(storedProto proto: Agentkeyring_V2_StoredMacFirstRun) throws {
        let practice: MacFirstRunPracticeState
        switch proto.practiceState {
        case .notSent:
            practice = .notSent
        case .waiting:
            guard let id = UUID(uuidString: proto.practiceID) else {
                throw CodecError.invalidPractice
            }
            practice = .waiting(id: id)
        case .approved:
            practice = .approved
        case .denied:
            practice = .denied(reply: proto.practiceReply)
        case .unspecified, .UNRECOGNIZED:
            throw CodecError.invalidPractice
        }

        let step: MacFirstRunStep
        switch proto.step {
        case .welcome:
            step = .welcome
        case .practice:
            step = .practice
        case .privacy:
            step = .privacy
        case .copy:
            step = .copy
        case .connectAgent:
            switch proto.connectAgentState {
            case .notTried:
                step = .connectAgent(.notTried)
            case .worked:
                step = .connectAgent(.worked(agent: proto.connectAgentName))
            case .denied:
                step = .connectAgent(.denied(agent: proto.connectAgentName))
            case .unspecified, .UNRECOGNIZED:
                throw CodecError.invalidConnectAgent
            }
        case .ready:
            step = .ready
        case .finished:
            step = .finished
        case .unspecified, .UNRECOGNIZED:
            throw CodecError.invalidStep
        }

        self.init(step: step, practice: practice)
    }

    func storedProto() -> Agentkeyring_V2_StoredMacFirstRun {
        var proto = Agentkeyring_V2_StoredMacFirstRun()
        switch step {
        case .welcome:
            proto.step = .welcome
        case .practice:
            proto.step = .practice
        case .privacy:
            proto.step = .privacy
        case .copy:
            proto.step = .copy
        case let .connectAgent(outcome):
            proto.step = .connectAgent
            switch outcome {
            case .notTried:
                proto.connectAgentState = .notTried
            case let .worked(agent):
                proto.connectAgentState = .worked
                proto.connectAgentName = agent
            case let .denied(agent):
                proto.connectAgentState = .denied
                proto.connectAgentName = agent
            }
        case .ready:
            proto.step = .ready
        case .finished:
            proto.step = .finished
        }

        switch practice {
        case .notSent:
            proto.practiceState = .notSent
        case let .waiting(id):
            proto.practiceState = .waiting
            proto.practiceID = id.uuidString
        case .approved:
            proto.practiceState = .approved
        case let .denied(reply):
            proto.practiceState = .denied
            proto.practiceReply = reply
        }
        return proto
    }
}

/// The last practice request sent to one device: shown in Devices, by device key. Not saved.
public enum PracticeResult: Equatable, Sendable {
    /// Asked for; not yet with Apple.
    case sent
    /// Apple has the notification.
    case withApple(at: Date)
    case approved(at: Date)
    case denied(at: Date, reply: String)
    case unanswered
    case failed(String)
}

/// What a copy from Passwords changed since the list the other devices last
/// received: added, changed (its last-changed date moved) and removed.
public struct UnsentVaultChanges: Equatable, Sendable {
    public var added: Int
    public var changed: Int
    public var removed: Int
    public var total: Int { added + changed + removed }

    public init(added: Int = 0, changed: Int = 0, removed: Int = 0) {
        self.added = added
        self.changed = changed
        self.removed = removed
    }

    /// `sent` and `now`: each password's id and its last-changed date. A password
    /// with no last-changed date (the test password) never counts as changed.
    public init(sent: [String: Date?], now: [String: Date?]) {
        added = now.keys.filter { sent[$0] == nil }.count
        removed = sent.keys.filter { now[$0] == nil }.count
        changed = now.filter { id, date in
            guard let recorded = sent[id], let recorded else { return false }
            return date != recorded
        }.count
    }
}

/// First run's states and events as the diagnostic log names them: the case and its request ID, never his
/// reply or an agent's name.
extension MacFirstRunFlow {
    var diagnosticName: String {
        let step = switch step {
        case .welcome: "welcome"
        case .practice: "practice"
        case .privacy: "privacy"
        case .copy: "copy"
        case .connectAgent(.notTried): "connectAgent.notTried"
        case .connectAgent(.worked): "connectAgent.worked"
        case .connectAgent(.denied): "connectAgent.denied"
        case .ready: "ready"
        case .finished: "finished"
        }
        let practice = switch practice {
        case .notSent: "notSent"
        case let .waiting(id): "waiting(\(id))"
        case .approved: "approved"
        case .denied: "denied"
        }
        return step + "/" + practice
    }
}

extension MacFirstRunEvent {
    var diagnosticName: String {
        switch self {
        case .getStarted: "getStarted"
        case .back: "back"
        case .continueOn: "continueOn"
        case let .sendPractice(id): "sendPractice(\(id))"
        case let .practiceApproved(id): "practiceApproved(\(id))"
        case let .practiceDenied(id, _): "practiceDenied(\(id))"
        case .useTestPasswordOnly: "useTestPasswordOnly"
        case let .agentAnswered(_, approved): approved ? "agentApproved" : "agentDenied"
        case .skipTest: "skipTest"
        case .showPasswords: "showPasswords"
        }
    }
}
#endif
