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
    /// The lease was approved by the password's Automatic rule, also after it ended.
    public var byAutomaticRule: Bool

    public init(
        id: String,
        login: RequestedLogin,
        agent: RequestingAgent,
        access: RequestedAccess,
        agentReason: String,
        askedAt: Date,
        state: AccessRequestState,
        events: [AccessRequestEvent] = [],
        answerIsQueued: Bool = false,
        byAutomaticRule: Bool = false
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
        self.byAutomaticRule = byAutomaticRule
    }
}

extension AccessRequest {
    /// First run's practice request, in FirstRunCopy's words.
    public static func practice(id: String, state: AccessRequestState) -> AccessRequest {
        AccessRequest(id: id, login: RequestedLogin(site: FirstRunCopy.practiceSite, account: FirstRunCopy.practiceAccount),
            agent: RequestingAgent(name: FirstRunCopy.practiceAgent, machine: "", address: "", isLocal: true),
            access: .practice, agentReason: FirstRunCopy.practiceReason, askedAt: .now, state: state)
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
    /// Claim: the name of the Git repository the agent says it is working in.
    public var project: String?
    /// Fact: the request came from the device showing it (a local agent on
    /// this Mac), not through the relay from another machine.
    public var isLocal: Bool

    public init(name: String, machine: String, address: String, folder: String? = nil, project: String? = nil, isLocal: Bool = false) {
        self.name = name
        self.machine = machine
        self.address = address
        self.folder = folder
        self.project = project
        self.isLocal = isLocal
    }
}

/// What a request asks for.
public enum RequestedAccess: Hashable, Sendable {
    /// A password, which the agent may fill or read for this task, 30 minutes at most.
    case login
    /// First run's practice request: laid out as a real one, with "Practice"
    /// where a real one shows the project. No real password is used.
    case practice
    /// Not a password: a computer or device asking to be added. The panel
    /// shows `lead`, the request's site in large type (the name), `detail` if
    /// any, the agent's reason if any, and `footer`; `denied` is the line under
    /// "Denied" once he has denied it. `replies`: an agent asked, so the reply
    /// box is there as on a password request; otherwise Deny takes its place.
    case setUp(lead: String, detail: String, footer: String, denied: String, replies: Bool)

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
    /// Josh answered on this device and the relay has the answer durably, but
    /// the lease is still PENDING until the Mac commits the outcome (RFC 0006).
    /// Keeps the chosen answer and any typed reply. Never answerable again.
    case waitingForMac(AnswerChoice, reply: String?)
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

    public var isWaitingForMac: Bool {
        if case .waitingForMac = self { return true }
        return false
    }

    public var isInUse: Bool {
        if case .approved = self { return true }
        return false
    }

    /// The reply Josh typed with a denial, sent or still on its way.
    public var reply: String? {
        switch self {
        case let .denied(_, reply, _), let .waitingForMac(.deny, reply): reply
        default: nil
        }
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
