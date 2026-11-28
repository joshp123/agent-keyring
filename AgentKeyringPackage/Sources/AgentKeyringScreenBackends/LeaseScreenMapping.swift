// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Turns a lease record into what the approval screens show, following the
// tables in RFC 0007. The screens never see protobuf types; this is the one
// place that reads them.

import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringProtocol
import Foundation

public enum LeaseScreenMapping {
    /// - Parameters:
    ///   - requester: the process attribution the store kept for the lease.
    ///   - login: the vault record the lease names, if it still exists.
    public static func accessRequest(_ lease: Agentkeyring_V2_Lease, requester: CredentialLeaseRequester?,
        login: CredentialCandidate?) -> AccessRequest {
        let agentName = requester?.name ?? lease.authorityContext.recipient.clientLabel
        let machine = requester?.machineName ?? lease.authorityContext.recipient.machineLabel
        return AccessRequest(
            id: lease.requestID,
            login: RequestedLogin(
                site: siteLabel(lease.authorityContext.sites.first ?? login?.origins.first ?? login?.title ?? "Unknown site"),
                account: login?.username ?? login?.title ?? "Unknown account"),
            agent: RequestingAgent(
                name: agentName,
                machine: machine,
                address: requester?.networkAddress ?? "",
                folder: requester?.workingDirectory.map(abbreviatingHome),
                project: requester?.project,
                isLocal: true),
            access: .login,
            agentReason: lease.authorityContext.reason,
            askedAt: date(lease.requestedAtUnixSeconds),
            state: state(lease),
            events: events(lease, agentName: agentName, machine: machine),
            byAutomaticRule: lease.automatic)
    }

    static func state(_ lease: Agentkeyring_V2_Lease) -> AccessRequestState {
        let ended = date(lease.endedAtUnixSeconds)
        switch lease.state {
        case .waiting:
            return .waitingForYou(until: date(lease.answerByUnixSeconds))
        case .approved:
            return .approved(by: decisionSurface(lease), until: date(lease.notAfterUnixSeconds))
        case .denied:
            return .denied(by: decisionSurface(lease), reply: lease.reply.isEmpty ? nil : lease.reply,
                askAgainAfter: lease.retryNotBeforeUnixSeconds > 0 ? date(lease.retryNotBeforeUnixSeconds) : nil)
        case .unanswered:
            return .unanswered
        case .cancelled:
            return .cancelled
        case .expired:
            return .expired(at: ended)
        case .released:
            return .released(at: ended)
        case .ended:
            return .ended(at: ended)
        case .unspecified, .UNRECOGNIZED:
            return .unanswered
        }
    }

    static func decisionSurface(_ lease: Agentkeyring_V2_Lease) -> ApprovalSurface {
        if lease.automatic { return .automaticRule }
        switch lease.authorityContext.decidingDeviceKind {
        case .iphone: return .iPhone
        case .watch: return .watch
        case .mac, .unspecified, .UNRECOGNIZED: return .mac
        }
    }

    static func events(_ lease: Agentkeyring_V2_Lease, agentName: String, machine: String) -> [AccessRequestEvent] {
        var events = [AccessRequestEvent(date(lease.requestedAtUnixSeconds), "\(agentName) asked on \(machine)")]
        if lease.approvedAtUnixSeconds > 0 {
            let how = switch decisionSurface(lease) {
            case .automaticRule: "Approved by rule"
            case .iPhone: "You approved with Face ID"
            case .watch: "You approved on Apple Watch"
            case .mac: "You approved on your Mac"
            }
            events.append(AccessRequestEvent(date(lease.approvedAtUnixSeconds), how))
        }
        if lease.endedAtUnixSeconds > 0 {
            let what = switch lease.state {
            case .denied: lease.reply.isEmpty ? "You denied it" : "You denied and replied"
            case .unanswered: "Nobody answered in time"
            case .cancelled: "\(agentName) stopped asking"
            case .expired: "Ended after 30 minutes"
            case .released: "\(agentName) said it was done"
            case .ended: "Ended early"
            case .unspecified, .waiting, .approved, .UNRECOGNIZED: "Ended"
            }
            events.append(AccessRequestEvent(date(lease.endedAtUnixSeconds), what))
        }
        return events
    }

    /// "github.com" from "https://github.com/login".
    static func siteLabel(_ site: String) -> String {
        URL(string: site)?.host() ?? site
    }

    static func abbreviatingHome(_ path: String) -> String {
        // The sandbox's home is the app's container; the agent's is the user's.
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return path }
        let home = String(cString: dir)
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func date(_ unixSeconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }
}
