// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// What the screens show about one request. Plain values, so a view never
// talks to the network or the vault: a backend builds them from a Lease
// (proto/agentkeyring/v1/agentkeyring.proto). RFC 0007 lists where each field
// comes from and which are facts and which are the agent's claims.

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
    /// Josh answered, but the answer is still waiting to reach the relay.
    public var answerIsQueued: Bool

    public init(
        id: String,
        login: RequestedLogin,
        agent: RequestingAgent,
        access: RequestedAccess,
        agentReason: String,
        askedAt: Date,
        state: AccessRequestState,
        events: [AccessRequestEvent] = [],
        answerIsQueued: Bool = false
    ) {
        self.id = id
        self.login = login
        self.agent = agent
        self.access = access
        self.agentReason = agentReason
        self.askedAt = askedAt
        self.state = state
        self.events = events
        self.answerIsQueued = answerIsQueued
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
    /// Claim. For example "Codex" or "Claude Code", from process attribution
    /// locally or the client's label remotely. Never proof of identity.
    public var name: String
    /// Fact: the machine's enrolled label.
    public var machine: String
    /// Fact: the machine's tailnet address, as Agent Keyring saw the connection.
    public var address: String
    /// Claim: the folder the agent says it is working in.
    public var folder: String?
    /// Fact: the request came from the device showing it (a local agent on
    /// this Mac), not through the relay from another machine.
    public var isLocal: Bool

    public init(name: String, machine: String, address: String, folder: String? = nil, isLocal: Bool = false) {
        self.name = name
        self.machine = machine
        self.address = address
        self.folder = folder
        self.isLocal = isLocal
    }
}

/// Lease purpose.
public enum RequestedAccess: Hashable, Sendable {
    /// PURPOSE_BROWSER_SIGN_IN: Agent Keyring fills the sign-in form itself.
    case signIn
    /// PURPOSE_PROGRAM: the value goes on standard input to the approved
    /// command, shown as typed, for example "gh auth login --with-token".
    case program(String)
    /// PURPOSE_AGENT_PROCESS: the value goes to the agent's own code. No
    /// protection beyond keeping it out of the transcript.
    case agentProcess

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
    /// `askAgainAfter`: new requests for this login from this machine are
    /// refused until then, unless Josh lets it ask again.
    case denied(by: ApprovalSurface, reply: String?, askAgainAfter: Date?)
    /// Nobody answered before the agent stopped waiting.
    case unanswered
    /// The agent stopped asking before anyone answered.
    case cancelled
    /// The 30 minutes ran out before the agent released the login.
    case expired(at: Date)
    /// The agent said it was done.
    case released(at: Date)
    /// Ended early: Josh ended it, or blocked the login or the machine (REVOKED).
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

    /// A denial that still stops this machine asking for the login again.
    public func isHoldingOffNewRequests(now: Date) -> Bool {
        if case let .denied(_, _, askAgainAfter?) = self { return askAgainAfter > now }
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
