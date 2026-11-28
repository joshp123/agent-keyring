// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// Before first run: this Mac's keys (docs/state-machines.md, "This Mac's
// keys"). A Mac with Touch ID makes its keys by itself. A Mac without Touch ID
// asks first how it is used: a Mac for agents gets only the command-line tool,
// and a personal Mac can opt in to approving with its Mac password. A Mac with
// no Secure Enclave can only be a Mac for agents. Not saved: until keys exist,
// every launch starts again from the facts.

#if os(macOS)
import AgentKeyringApprovalCore
import Foundation

public enum MacHardwareSetupEvent: Equatable, Sendable {
    /// Launch looked for saved keys and read what this Mac has (`start`).
    case looked(keysSaved: Bool, hardware: MacHardware)
    case chooseForAgents
    case choosePersonalMac
    case back
    case keysMade
    case keysFailed(String)
    case tryAgain
}

public enum MacHardwareSetupFlow: Equatable, Sendable {
    /// The keys are not looked for yet.
    case loading
    /// This Mac's keys exist, or a Mac with Touch ID makes them when first
    /// needed: first run, or the main window once first run is finished.
    case ready
    /// The keys could not be read or made, with the reason.
    case keysFailed(String)
    /// No Secure Enclave: this Mac can only be a Mac for agents.
    case noSecureEnclave
    /// No keys yet and no Touch ID: "How do you use this Mac?"
    case askHowUsed
    /// He chose "A Mac for agents": the command-line tool, not this app.
    case forAgents
    /// He chose "My personal Mac": the trade-off, before keys are made, and
    /// why making them failed if it did.
    case personalMac(failure: String?)

    /// Where setup starts. Saved keys are always used as they are: a Mac
    /// whose Touch ID keyboard is gone keeps its Touch ID keys, and is never
    /// asked how it is used.
    public static func initialFlow(keysSaved: Bool, hardware: MacHardware) -> MacHardwareSetupFlow {
        if keysSaved { return .ready }
        switch hardware {
        case .touchID: return .ready
        case .noTouchID: return .askHowUsed
        case .noSecureEnclave: return .noSecureEnclave
        }
    }

    /// The next state; an event with no arrow leaves it as it is. Every state
    /// names every event, so a new state or event does not compile until it is
    /// given its arrows. While he is choosing how he uses this Mac, only his
    /// own choices move it: keys found or made in the background do not.
    public func after(_ event: MacHardwareSetupEvent) -> MacHardwareSetupFlow {
        switch self {
        case .loading:
            switch event {
            case let .looked(keysSaved, hardware): Self.initialFlow(keysSaved: keysSaved, hardware: hardware)
            case .keysMade: .ready
            case let .keysFailed(reason): .keysFailed(reason)
            case .chooseForAgents, .choosePersonalMac, .back, .tryAgain: self
            }
        case .ready:
            switch event {
            case .keysMade: .ready
            case let .keysFailed(reason): .keysFailed(reason)
            case .looked, .chooseForAgents, .choosePersonalMac, .back, .tryAgain: self
            }
        case .keysFailed:
            switch event {
            case .keysMade: .ready
            case .tryAgain: .loading
            case .looked, .chooseForAgents, .choosePersonalMac, .back, .keysFailed: self
            }
        case .askHowUsed:
            switch event {
            case .chooseForAgents: .forAgents
            case .choosePersonalMac: .personalMac(failure: nil)
            case .looked, .back, .keysMade, .keysFailed, .tryAgain: self
            }
        case .forAgents:
            switch event {
            case .back: .askHowUsed
            case .looked, .chooseForAgents, .choosePersonalMac, .keysMade, .keysFailed, .tryAgain: self
            }
        case .personalMac:
            switch event {
            case .back: .askHowUsed
            case .keysMade: .ready
            case let .keysFailed(reason): .personalMac(failure: reason)
            case .looked, .chooseForAgents, .choosePersonalMac, .tryAgain: self
            }
        case .noSecureEnclave:
            switch event {
            case .looked, .chooseForAgents, .choosePersonalMac, .back, .keysMade, .keysFailed, .tryAgain: self
            }
        }
    }

    /// Keys may be read or made by themselves (on a Mac with Touch ID) only
    /// here; while he is choosing, or with no Secure Enclave, they wait for him.
    var makesKeysItself: Bool {
        switch self {
        case .loading, .ready, .keysFailed: true
        case .noSecureEnclave, .askHowUsed, .forAgents, .personalMac: false
        }
    }

    /// The window shows setup in place of first run and the main window.
    public var isAsking: Bool { self != .ready && self != .loading }
}
#endif
