// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// One request as the Watch shows it, from the push's signed request envelope and what the
// iPhone handed over. The words follow Paper's page "The request".

#if os(watchOS)
import AgentKeyringProtocol
import Foundation

public enum WatchRequestState: Sendable, Equatable {
    case waiting
    case ended(String, approved: Bool = false)
}

enum UnreadableWatchRequestError: Error, CustomStringConvertible {
    case noNotice, notSetUp, unknownMachine, notSigned
    var description: String {
        switch self {
        case .noNotice: "the push carried no notice"
        case .notSetUp: "Apple Watch has no Members yet"
        case .unknownMachine: "the asking machine is not in Members"
        case .notSigned: "the request was not signed by the machine it names"
        }
    }
}

public struct WatchRequest: Sendable, Equatable {

    public let envelope: Data            // The serialized signed request envelope, kept for answering.
    public let id: String
    public let site: String
    public let account: String
    public let sites: [String]
    public let agent: String         // "Codex"
    public let wants: String         // "Codex on Mac mini wants"
    public let project: String?
    public let reason: String
    public let state: WatchRequestState
    /// "Claude Code on MacBook Pro".
    public let who: String
    /// While an approval lasts: when it ends.
    public let inUseUntil: Date?
    /// When the waiting request times out if unanswered.
    public let answerBy: Date
    /// The practice request the iPhone asks for after adding this Apple Watch.
    public let isPractice: Bool
    /// Exact catalogue version, title and recipient key shown on the card; re-checked at approval time.
    let loginVersion: UInt64
    let loginTitle: String
    public let recipientKey: Data

    public init(envelope: Data, id: String, site: String, account: String, sites: [String], agent: String, wants: String,
                project: String?, reason: String, state: WatchRequestState, who: String, inUseUntil: Date?, answerBy: Date = .distantFuture,
                isPractice: Bool, loginVersion: UInt64 = 0, loginTitle: String = "", recipientKey: Data = Data()) {
        self.envelope = envelope; self.id = id; self.site = site; self.account = account; self.sites = sites; self.agent = agent
        self.wants = wants; self.project = project; self.reason = reason; self.state = state; self.who = who
        self.inUseUntil = inUseUntil; self.answerBy = answerBy; self.isPractice = isPractice
        self.loginVersion = loginVersion; self.loginTitle = loginTitle; self.recipientKey = recipientKey
    }

    /// Opens the push's notice and names everything in it. Fails with one
    /// reason, for the report; the Watch then shows a plain line.
    public static func from(userInfo: [AnyHashable: Any], keys: WatchKeys, saved: WatchPersistedState) throws -> WatchRequest {
        if let base64 = userInfo[envelopeKey] as? String, let bytes = Data(base64Encoded: base64) {
            return try from(envelope: Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: bytes), saved: saved, ownKeyID: keys.keyID())
        }
        guard let base64 = userInfo["akr"] as? String, let bytes = Data(base64Encoded: base64) else { throw UnreadableWatchRequestError.noNotice }
        let notice = try Agentkeyring_V2_Notice(serializedBytes: bytes)
        return try from(envelope: keys.openNotice(notice, deviceKeyID: keys.keyID()), saved: saved, ownKeyID: keys.keyID())
    }

    /// Where the extension leaves the opened signed request envelope for the app's own layout.
    static let envelopeKey = "akrRequestEnvelope"

    public static func from(envelope: Agentkeyring_V2_SignedRequestEnvelope, saved: WatchPersistedState, ownKeyID: String, now: Date = .now) throws -> WatchRequest {
        let request = try CredentialSealing.parseRequest(envelope.request)
        guard let members = saved.signedMembers else { throw UnreadableWatchRequestError.notSetUp }
        let answerBy = request.answerByUnixSeconds > 0
            ? Date(timeIntervalSince1970: Double(request.answerByUnixSeconds))
            : .distantFuture
        let effective = CredentialRequestLifecycle.effectiveState(of: envelope, now: now)
        let approved = [.approved, .ended, .expired, .released].contains(effective)
        // This Apple Watch's own practice request: no computer and no password, the board's words.
        if try isOwnPractice(envelope, members: members, ownKeyID: ownKeyID) {
            let state: WatchRequestState
            if envelope.hasOutcome {
                var effectiveOutcome = envelope.outcome
                if (effectiveOutcome.state == .waiting || effectiveOutcome.state == .approved), effective != effectiveOutcome.state {
                    effectiveOutcome.state = effective
                }
                state = .ended(outcome(effectiveOutcome, members: members, agent: "The practice", minutes: 10), approved: approved)
            } else if effective == .unanswered {
                var expired = Agentkeyring_V2_Lease()
                expired.state = .unanswered
                state = .ended(outcome(expired, members: members, agent: "The practice", minutes: 10), approved: false)
            } else {
                state = .waiting
            }
            return WatchRequest(envelope: try envelope.serializedData(), id: request.requestID, site: "example.com", account: "you@example.com",
                                sites: [], agent: "Agent Keyring", wants: "Practice: an agent wants", project: nil,
                                reason: "You asked me to download October’s invoice.", state: state, who: "Practice", inUseUntil: nil,
                                answerBy: answerBy, isPractice: true)
        }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { throw UnreadableWatchRequestError.unknownMachine }
        // Named from the signed Catalogue the iPhone handed over, never from what the relay sends beside the request.
        // Throws on missing or Blocked logins instead of rendering raw UUIDs.
        let login = try CredentialSealing.signedLogin(for: request, in: saved.signedCatalogue)
        let agent = request.agent.isEmpty ? "An agent" : request.agent
        let minutes = max(1, Int((request.answerByUnixSeconds - request.askedUnixSeconds) / 60))
        let state: WatchRequestState
        if envelope.hasOutcome {
            var effectiveOutcome = envelope.outcome
            if (effectiveOutcome.state == .waiting || effectiveOutcome.state == .approved), effective != effectiveOutcome.state {
                effectiveOutcome.state = effective
            }
            state = .ended(outcome(effectiveOutcome, members: members, agent: agent, minutes: minutes), approved: approved)
        } else if effective == .unanswered {
            var expired = Agentkeyring_V2_Lease()
            expired.state = .unanswered
            state = .ended(outcome(expired, members: members, agent: agent, minutes: minutes), approved: false)
        } else {
            state = .waiting
        }
        let until = effective == .approved && envelope.outcome.notAfterUnixSeconds > Int64(now.timeIntervalSince1970)
            ? Date(timeIntervalSince1970: Double(envelope.outcome.notAfterUnixSeconds)) : nil
        return WatchRequest(
            envelope: try envelope.serializedData(), id: request.requestID,
            site: site(login), account: login.account, sites: login.sites,
            agent: agent, wants: "\(agent) on \(machine.label) wants", project: request.project.isEmpty ? nil : request.project,
            reason: request.reason, state: state, who: "\(agent) on \(machine.label)", inUseUntil: until, answerBy: answerBy, isPractice: false,
            loginVersion: login.version, loginTitle: login.title, recipientKey: machine.receivingPublicKey)
    }

    static func site(_ login: Agentkeyring_V2_Login) -> String {
        login.sites.first.flatMap { URL(string: $0)?.host ?? $0 } ?? login.title
    }

    /// The outcome as Paper's table words it ("The request", "Your answer").
    static func outcome(_ lease: Agentkeyring_V2_Lease, members: Members, agent: String, minutes: Int) -> String {
        let on = members.devices.first { $0.label == lease.answeredBy }.map { device -> String in
            switch device.kind {
            case .watch: "on your Apple Watch"
            case .iphone: "on your iPhone"
            case .mac: "on your Mac"
            default: "on \(device.label)"
            }
        }
        switch lease.state {
        case .approved, .ended, .expired, .released:
            return on.map { "Approved \($0)." } ?? "Approved."
        case .denied:
            let denied = on.map { "Denied \($0)." } ?? "Denied."
            return lease.reply.isEmpty ? denied : "\(denied) You told \(agent): “\(lease.reply)”"
        case .unanswered:
            return "No answer. The request ended after \(minutes) minutes, and \(agent) can ask again."
        case .cancelled:
            return "Cancelled. \(agent) stopped asking before you answered."
        case .waiting, .unspecified, .UNRECOGNIZED:
            return "Ended."
        }
    }
}
#endif
