// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
// In its own module, so the notification service extension needs no screens.
//
// What a request's notification says on the Lock Screen, and what replaces it
// once the request has ended.

import AgentKeyringApprovalCore
import Foundation

public enum PhoneNotificationCopy {
    public static func notificationTitle(_ request: AccessRequest) -> String { request.login.site }
    /// The ledger puts who asks in the subtitle; iOS cuts a subtitle to one line, so it leads the body instead.
    public static func notificationSubtitle(_ agent: RequestingAgent) -> String {
        agent.machine.isEmpty ? "\(agent.name) wants this password" : "\(agent.name) on \(agent.machine) wants this password"
    }
    public static func notificationBody(_ request: AccessRequest) -> String {
        "\(request.login.account): \(PhoneCopy.quoted(request.agentReason))"
    }
    public static let practiceNotificationBody = "Practice request: “You asked me to download October’s invoice.”"
    public static let notificationFallbackTitle = "An agent wants to use a password."
    public static let notificationFallbackBody = "Open Agent Keyring to see the request."
    /// The push that replaces a request on the Lock Screen once it has ended.
    public static func outcomeBody(_ request: AccessRequest, answeredBy device: String?) -> String {
        let on = device.map { " on your \($0)" } ?? ""
        switch request.state {
        case let .approved(_, until): return "Approved\(on). \(request.agent.name) can use this password until \(PhoneCopy.clock(until)) at the latest."
        case let .denied(_, reply?, _): return "Denied\(on). You told \(request.agent.name): \(PhoneCopy.quoted(reply))"
        case .denied: return "Denied\(on)."
        case .unanswered: return "No answer. The request ended after 10 minutes, and \(request.agent.name) can ask again."
        case .cancelled: return "Cancelled. \(request.agent.name) stopped asking before you answered."
        default: return "This request has ended."
        }
    }
}
