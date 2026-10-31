// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Turns a lease record into what the approval screens show, following the
// tables in RFC 0007. The screens never see protobuf types; this is the one
// place that reads them.

import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import Foundation

public enum LeaseScreenMapping {
    /// - Parameters:
    ///   - requester: the process attribution the store kept for the lease.
    ///   - login: the vault record the lease names, if it still exists.
    public static func accessRequest(_ lease: Agentkeyring_V1_Lease, requester: CredentialLeaseRequester?,
        login: CredentialCandidate?) -> AccessRequest {
        let agentName = requester?.name ?? lease.recipient.clientLabel
        let machine = requester?.machineName ?? lease.recipient.machineLabel
        return AccessRequest(
            id: lease.leaseID,
            login: RequestedLogin(
                site: siteLabel(lease.sites.first ?? login?.origins.first ?? login?.title ?? "Unknown site"),
                account: login?.username ?? login?.title ?? "Unknown account"),
            agent: RequestingAgent(
                name: agentName,
                machine: machine,
                address: requester?.networkAddress ?? "this Mac",
                folder: requester?.workingDirectory.map(abbreviatingHome)),
            access: access(lease),
            agentReason: lease.reason,
            askedAt: date(lease.requestedAtUnixSeconds),
            state: state(lease),
            events: events(lease, agentName: agentName, machine: machine))
    }

    static func access(_ lease: Agentkeyring_V1_Lease) -> RequestedAccess {
        switch lease.purpose {
        case .program:
            .program(([lease.program.executable] + lease.program.arguments).joined(separator: " "))
        case .agentProcess:
            .agentProcess
        default:
            .signIn
        }
    }

    static func state(_ lease: Agentkeyring_V1_Lease) -> AccessRequestState {
        let ended = date(lease.endedAtUnixSeconds)
        switch lease.state {
        case .pending:
            return .waitingForYou(until: date(lease.pendingUntilUnixSeconds))
        case .active:
            return .approved(by: surface(lease.approvedBy), until: date(lease.notAfterUnixSeconds))
        case .denied:
            return .denied(by: surface(lease.approvedBy), reply: lease.reply.isEmpty ? nil : lease.reply,
                askAgainAfter: lease.retryNotBeforeUnixSeconds > 0 ? date(lease.retryNotBeforeUnixSeconds) : nil)
        case .unanswered:
            return .unanswered
        case .cancelled:
            return .cancelled
        case .expired:
            return .expired(at: ended)
        case .released:
            return .released(at: ended)
        case .revoked:
            return .ended(at: ended)
        default:
            return .unanswered
        }
    }

    static func surface(_ approvedBy: Agentkeyring_V1_ApprovedBy) -> ApprovalSurface {
        switch approvedBy {
        case .automaticRule: .automaticRule
        case .iphone: .iPhone
        default: .mac
        }
    }

    static func events(_ lease: Agentkeyring_V1_Lease, agentName: String, machine: String) -> [AccessRequestEvent] {
        var events = [AccessRequestEvent(date(lease.requestedAtUnixSeconds), "\(agentName) asked on \(machine)")]
        if lease.approvedAtUnixSeconds > 0 {
            let how = switch lease.approvedBy {
            case .automaticRule: "Approved by rule"
            case .iphone: "You approved with Face ID"
            default: "You approved with Touch ID"
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
            case .revoked: "Ended early"
            default: "Ended"
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.hasPrefix(trimmedHome) ? "~" + path.dropFirst(trimmedHome.count) : path
    }

    static func date(_ unixSeconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }
}
