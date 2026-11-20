// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The words of a request as a notification carries them between the
// notification service extension, the held layout and the app. The
// extension puts them in `userInfo["request"]` once it has them; the push
// itself carries nothing readable (the core decides whether they arrive
// sealed in the push or are fetched by id).

import Foundation

public enum PhoneNotification {
    /// The category of a request's notification on the iPhone and the Watch.
    public static let requestCategory = "REQUEST"
    public static let approveAction = "APPROVE"
    public static let denyAction = "DENY"
    public static let denyAndExplainAction = "DENY_EXPLAIN"
    public static let wordsKey = "request"

    /// The request id from any notification of ours, with or without words.
    public static func requestID(_ userInfo: [AnyHashable: Any]) -> String? {
        (userInfo[wordsKey] as? [String: Any])?["id"] as? String ?? userInfo["id"] as? String
    }

    /// The request a silent push says has been answered or has ended: its top-level "id".
    public static func ended(_ userInfo: [AnyHashable: Any]) -> String? {
        let aps = userInfo["aps"] as? [String: Any]
        guard aps?["alert"] == nil, let id = userInfo["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    public static func encode(_ request: AccessRequest, deadline: Date) -> [String: Any] {
        var words: [String: Any] = [
            "id": request.id, "site": request.login.site, "account": request.login.account,
            "agent": request.agent.name, "machine": request.agent.machine, "reason": request.agentReason,
            "asked": request.askedAt.timeIntervalSince1970, "deadline": deadline.timeIntervalSince1970,
        ]
        words["project"] = request.agent.project
        words["folder"] = request.agent.folder
        return words
    }

    public static func decode(_ userInfo: [AnyHashable: Any]) -> AccessRequest? {
        guard let words = userInfo[wordsKey] as? [String: Any],
              let id = words["id"] as? String, let site = words["site"] as? String,
              let account = words["account"] as? String, let agent = words["agent"] as? String,
              let machine = words["machine"] as? String, let reason = words["reason"] as? String,
              let deadline = words["deadline"] as? Double else { return nil }
        let asked = (words["asked"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
        return AccessRequest(
            id: id, login: RequestedLogin(site: site, account: account),
            agent: RequestingAgent(name: agent, machine: machine, address: "",
                                   folder: words["folder"] as? String, project: words["project"] as? String),
            access: .login, agentReason: reason, askedAt: asked,
            state: .waitingForYou(until: Date(timeIntervalSince1970: deadline)))
    }
}
