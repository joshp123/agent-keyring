// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// One request as the Watch shows it, from the push's Work and what the
// iPhone handed over. The words follow Paper's page "The request".

#if os(watchOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

public struct WatchRequest: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case waiting
        case ended(String)
    }

    public let work: Data            // The serialized Work, kept for answering.
    public let id: String
    public let site: String
    public let account: String
    public let sites: [String]
    public let agent: String         // "Codex"
    public let wants: String         // "Codex on Mac mini wants"
    public let project: String?
    public let reason: String
    public let state: State

    /// Opens the push's notice and names everything in it. Fails with one
    /// reason, for the report; the Watch then shows a plain line.
    public static func from(userInfo: [AnyHashable: Any], keys: WatchKeys, saved: WatchSaved) throws -> WatchRequest {
        if let base64 = userInfo[workKey] as? String, let bytes = Data(base64Encoded: base64) {
            return try from(work: Agentkeyring_V2_Work(serializedBytes: bytes), saved: saved)
        }
        guard let base64 = userInfo["akr"] as? String, let bytes = Data(base64Encoded: base64) else { throw Unreadable.noNotice }
        let notice = try Agentkeyring_V2_Notice(serializedBytes: bytes)
        return try from(work: keys.openNotice(notice, deviceKeyID: keys.keyID()), saved: saved)
    }

    /// Where the extension leaves the opened Work for the app's own layout.
    public static let workKey = "akrWork"

    public static func from(work: Agentkeyring_V2_Work, saved: WatchSaved) throws -> WatchRequest {
        let request = try Sealing.parseRequest(work.request)
        guard let members = saved.signedMembers else { throw Unreadable.notSetUp }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { throw Unreadable.unknownMachine }
        // The push names the login from the signed catalogue; the saved one is a fallback.
        let login = work.hasLogin ? work.login : saved.signedCatalogue?.logins.first { $0.loginID == request.loginID }
        let agent = request.agent.isEmpty ? "An agent" : request.agent
        let minutes = max(1, Int((request.answerByUnixSeconds - request.askedUnixSeconds) / 60))
        let state: State = work.hasOutcome ? .ended(outcome(work.outcome, members: members, agent: agent, minutes: minutes)) : .waiting
        return WatchRequest(
            work: try work.serializedData(), id: request.requestID,
            site: login.map(site) ?? request.loginID, account: login?.account ?? "", sites: login?.sites ?? [],
            agent: agent, wants: "\(agent) on \(machine.label) wants", project: request.project.isEmpty ? nil : request.project,
            reason: request.reason, state: state)
    }

    public enum Unreadable: Error, CustomStringConvertible {
        case noNotice, notSetUp, unknownMachine
        public var description: String {
            switch self {
            case .noNotice: "the push carried no notice"
            case .notSetUp: "Apple Watch has no Members yet"
            case .unknownMachine: "the asking machine is not in Members"
            }
        }
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
        case .approved, .ended:
            return on.map { "Approved \($0)." } ?? "Approved."
        case .denied:
            let denied = on.map { "Denied \($0)." } ?? "Denied."
            return lease.reply.isEmpty ? denied : "\(denied) You told \(agent): “\(lease.reply)”"
        case .unanswered:
            return "No answer. The request ended after \(minutes) minutes, and \(agent) can ask again."
        case .cancelled:
            return "Withdrawn. \(agent) stopped asking before you answered."
        default:
            return "Ended."
        }
    }
}
#endif
