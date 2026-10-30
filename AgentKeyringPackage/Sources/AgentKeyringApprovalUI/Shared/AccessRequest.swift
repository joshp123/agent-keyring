// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// What the screens show about one request. Plain values, so a view never
// talks to the network or the vault: whoever owns the data fills these in.
// The fields follow proto/agentkeyring/v1/agentkeyring.proto.

import Foundation

public struct AccessRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public var login: RequestedLogin
    public var agent: RequestingAgent
    public var access: RequestedAccess
    /// The agent's own sentence about why it needs the login. Never verified.
    public var agentReason: String
    public var askedAt: Date
    public var state: AccessRequestState
    /// What happened, oldest first. Shown on the history detail screen.
    public var events: [AccessRequestEvent]

    public init(
        id: String,
        login: RequestedLogin,
        agent: RequestingAgent,
        access: RequestedAccess,
        agentReason: String,
        askedAt: Date,
        state: AccessRequestState,
        events: [AccessRequestEvent] = []
    ) {
        self.id = id
        self.login = login
        self.agent = agent
        self.access = access
        self.agentReason = agentReason
        self.askedAt = askedAt
        self.state = state
        self.events = events
    }
}

public struct RequestedLogin: Hashable, Sendable {
    public var site: String
    public var account: String

    public init(site: String, account: String) {
        self.site = site
        self.account = account
    }
}

public struct RequestingAgent: Hashable, Sendable {
    /// For example "Codex" or "Claude Code". Taken from the requesting process.
    public var name: String
    public var machine: String
    /// The machine's tailnet address, as Agent Keyring saw the connection.
    public var address: String
    public var folder: String?

    public init(name: String, machine: String, address: String, folder: String? = nil) {
        self.name = name
        self.machine = machine
        self.address = address
        self.folder = folder
    }
}

public enum RequestedAccess: Hashable, Sendable {
    /// Agent Keyring fills the sign-in form itself. The agent never gets the value.
    case signIn
    /// The value goes to a program the agent names, on its standard input.
    case program(String)

    public static let longestLease: TimeInterval = 30 * 60
}

public enum ApprovalSurface: String, Hashable, Sendable {
    case mac
    case iPhone
    case automaticRule
}

public enum AnswerChoice: Hashable, Sendable {
    case approve
    case deny
}

public enum AccessRequestState: Hashable, Sendable {
    /// Nobody has answered. The agent stops waiting at `until`.
    case waitingForYou(until: Date)
    /// Josh answered here; the answer is on its way to Agent Keyring.
    case sendingAnswer(AnswerChoice)
    /// The agent may use the login until `until`, or until it releases it.
    case approved(by: ApprovalSurface, until: Date)
    case denied(by: ApprovalSurface, reply: String?)
    /// Nobody answered before the agent stopped waiting.
    case unanswered
    /// The 30 minutes ran out before the agent released the login.
    case expired(at: Date)
    /// The agent said it was done.
    case released(at: Date)
    /// Josh ended the access early.
    case ended(at: Date)
    /// Blocked by the login's rule. Josh was not asked.
    case blockedByRule

    public var isWaitingForYou: Bool {
        if case .waitingForYou = self { return true }
        return false
    }

    public var isInUse: Bool {
        if case .approved = self { return true }
        return false
    }
}

public struct AccessRequestEvent: Hashable, Sendable {
    public var time: Date
    public var text: String

    public init(_ time: Date, _ text: String) {
        self.time = time
        self.text = text
    }
}
