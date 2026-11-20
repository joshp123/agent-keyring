// Written by AI on 2026.11.19 by model claude opus 5.5; rebuilt on 2026.11.20
// from the Paper board "Mac", ten steps, one window each.
//
// First run on the Mac: one journey, its steps built from the devices he
// chose, each window a state and each button a transition
// (docs/state-machines.md, "Mac first run"). The state holds only
// which window he is on and what he did there; facts the world owns (the
// passwords, whether Touch ID can be used, how far a copy from Passwords has
// got, which devices and computers have joined, the last practice result on
// each device) stay where they live and are read alongside it.

import AgentKeyringProtocol
import Foundation

public enum FirstRun: Codable, Equatable, Sendable {
    case welcome
    /// "Which devices do you want to use?": the journey's steps are built from his answer.
    case chooseDevices
    /// One window of the journey, for the devices he chose.
    case journey(Devices, Page)
    case finished

    /// The devices he chose to use beside this Mac.
    public struct Devices: Codable, Equatable, Sendable {
        public var iPhone: Bool
        public var watch: Bool
        public var computers: Bool
        public init(iPhone: Bool, watch: Bool, computers: Bool) {
            self.iPhone = iPhone
            self.watch = watch
            self.computers = computers
        }
        public static let thisMacAlone = Devices(iPhone: false, watch: false, computers: false)
        /// Any of them needs a computer that stays on.
        var needsAlwaysOn: Bool { iPhone || watch || computers }
    }

    public enum Page: Codable, Equatable, Sendable {
        /// The practice request is beside the window.
        case practice
        /// He denied it, with these words (empty if none); Try Again sends another.
        case practiceDenied(reply: String)
        /// "Copy your passwords": how far the copy has got is `PasswordsCopy`, shared with the main window.
        case copyPasswords
        /// "Tell your agents about Agent Keyring": the note he gives them, and "Try it now".
        case tellAgents(copied: Copied)
        /// A computer of his that stays on, which the iPhone, Apple Watch and other computers need.
        case stayingOn
        case addPhone
        case addWatch
        case addComputers
        /// "Try a request on each device".
        case tryDevices
        case ready
    }

    public enum Copied: Codable, Equatable, Sendable {
        case passwords(Int)
        case sample
    }

    public enum Event: Equatable, Sendable {
        case getStarted
        case chose(Devices)
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
        /// The iPhone finished its own first run, or the Apple Watch joined: the
        /// Mac's window for it moves on, as he did the step there.
        case deviceDone
        case done
    }

    /// What the world says is already done, so the journey passes over it.
    public struct Facts: Equatable, Sendable {
        public var alwaysOn = false
        public var iPhoneDone = false
        public var watchJoined = false
        public init(alwaysOn: Bool = false, iPhoneDone: Bool = false, watchJoined: Bool = false) {
            self.alwaysOn = alwaysOn
            self.iPhoneDone = iPhoneDone
            self.watchJoined = watchJoined
        }
    }

    /// The journey's windows for these devices, in order: the same list on every device.
    public static func pages(for devices: Devices) -> [Page] {
        var pages: [Page] = [.practice, .copyPasswords, .tellAgents(copied: .sample)]
        if devices.needsAlwaysOn { pages.append(.stayingOn) }
        if devices.iPhone { pages.append(.addPhone) }
        if devices.watch { pages.append(.addWatch) }
        if devices.computers { pages.append(.addComputers) }
        return pages + [.tryDevices, .ready]
    }

    /// The next state; an event with no arrow leaves it as it is.
    public func after(_ event: Event, facts: Facts = Facts()) -> FirstRun {
        switch (self, event) {
        case (.welcome, .getStarted): return .chooseDevices
        case let (.chooseDevices, .chose(devices)): return .journey(devices, .practice)
        case (.journey(_, .ready), .done): return .finished
        case let (.journey(devices, page), _):
            guard let next = Self.next(page, event, devices: devices, facts: facts) else { return self }
            return .journey(next.devices, next.page)
        default: return self
        }
    }

    private static func next(_ page: Page, _ event: Event, devices: Devices, facts: Facts) -> (devices: Devices, page: Page)? {
        switch (page, event) {
        case (.practice, .practicePassed): return (devices, .copyPasswords)
        case let (.practice, .practiceDenied(reply)): return (devices, .practiceDenied(reply: reply))
        case (.practiceDenied, .tryAgain): return (devices, .practice)
        case let (.copyPasswords, .imported(count)): return (devices, .tellAgents(copied: .passwords(count)))
        case (.copyPasswords, .useSample): return (devices, .tellAgents(copied: .sample))
        // His own passwords replace the sample.
        case let (.tellAgents, .imported(count)): return (devices, .tellAgents(copied: .passwords(count)))
        case (.tellAgents, .copyOwn), (.ready, .copyOwn): return (devices, .copyPasswords)
        case (.stayingOn, .useThisMacAlone): return (.thisMacAlone, .tryDevices)
        case (.stayingOn, .connected): return (devices, following(.stayingOn, devices, facts))
        case (.addPhone, .deviceDone) where facts.iPhoneDone: return (devices, following(page, devices, facts))
        case (.addWatch, .deviceDone) where facts.watchJoined: return (devices, following(page, devices, facts))
        case (.addPhone, .skip), (.addWatch, .skip), (.addComputers, .skip),
             (.tellAgents, .continueOn), (.addPhone, .continueOn), (.addWatch, .continueOn),
             (.addComputers, .continueOn), (.tryDevices, .continueOn):
            return (devices, following(page, devices, facts))
        default: return nil
        }
    }

    /// The page after this one in his journey, passing over what is already done.
    private static func following(_ page: Page, _ devices: Devices, _ facts: Facts) -> Page {
        let pages = pages(for: devices)
        let here = pages.firstIndex { $0.kind == page.kind } ?? 0
        for next in pages.dropFirst(here + 1) {
            switch next {
            case .stayingOn where facts.alwaysOn, .addPhone where facts.iPhoneDone, .addWatch where facts.watchJoined: continue
            default: return next
            }
        }
        return .ready
    }

    /// Where this is in the one journey, as every device reports it.
    public var step: JourneyStepKind {
        switch self {
        case .welcome: .welcome
        case .chooseDevices: .chooseDevices
        case let .journey(_, page): page.kind
        case .finished: .ready
        }
    }

    /// The devices he chose, once he has.
    public var devices: Devices? { if case let .journey(devices, _) = self { devices } else { nil } }

    /// On the practice request's window, where the practice panel shows.
    public var isPractice: Bool { if case .journey(_, .practice) = self { true } else { false } }

    /// The steps of his journey, for the status report and the step list.
    public var journey: [JourneyStepKind] {
        guard case let .journey(devices, _) = self else { return [.welcome, .chooseDevices] }
        return [.welcome, .chooseDevices] + Self.pages(for: devices).map(\.kind)
    }
}

/// The journey's steps by kind, as the status report names them.
public enum JourneyStepKind: Equatable, Sendable {
    case welcome, chooseDevices, practice, passwords, agents, alwaysOn, iPhone, watch, computers, tryDevices, ready
}

extension JourneyStepKind {
    var wire: Agentkeyring_V2_JourneyStep {
        switch self {
        case .welcome: .welcome
        case .chooseDevices: .chooseDevices
        case .practice: .practice
        case .passwords: .passwords
        case .agents: .agents
        case .alwaysOn: .alwaysOn
        case .iPhone: .iphone
        case .watch: .watch
        case .computers: .computers
        case .tryDevices: .tryDevices
        case .ready: .ready
        }
    }
}

extension FirstRun.Page {
    var kind: JourneyStepKind {
        switch self {
        case .practice, .practiceDenied: .practice
        case .copyPasswords: .passwords
        case .tellAgents: .agents
        case .stayingOn: .alwaysOn
        case .addPhone: .iPhone
        case .addWatch: .watch
        case .addComputers: .computers
        case .tryDevices: .tryDevices
        case .ready: .ready
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
