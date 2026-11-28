// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by models gemini-4-hydrogen and
// claude opus 5.5.
//
// The words of a request as a notification carries them between the
// notification service extension, the held layout and the app. The
// extension puts them in `userInfo["request"]` once it has them; the push
// itself carries nothing readable (the core decides whether they arrive
// sealed in the push or are fetched by id).

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import Foundation

extension PhoneNotification {
    /// The request id from any notification of ours: its words, or its top-level "id".
    public static func requestID(_ userInfo: [AnyHashable: Any]) -> String? {
        notified(userInfo)?.id ?? userInfo["id"] as? String
    }

    public static func encode(_ request: AccessRequest, deadline: Date) -> Data {
        var notified = Agentkeyring_V2_NotifiedRequest()
        notified.id = request.id
        notified.site = request.login.site
        notified.account = request.login.account
        notified.agent = request.agent.name
        notified.machine = request.agent.machine
        notified.reason = request.agentReason
        notified.askedUnixSeconds = request.askedAt.timeIntervalSince1970
        notified.deadlineUnixSeconds = deadline.timeIntervalSince1970
        notified.project = request.agent.project ?? ""
        notified.folder = request.agent.folder ?? ""
        return (try? notified.serializedData()) ?? Data()
    }

    public static func decode(_ userInfo: [AnyHashable: Any]) -> AccessRequest? {
        guard let notified = notified(userInfo) else { return nil }
        return AccessRequest(
            id: notified.id,
            login: RequestedLogin(site: notified.site, account: notified.account),
            agent: RequestingAgent(
                name: notified.agent,
                machine: notified.machine,
                address: "",
                folder: notified.folder.isEmpty ? nil : notified.folder,
                project: notified.project.isEmpty ? nil : notified.project
            ),
            access: .login,
            agentReason: notified.reason,
            askedAt: notified.askedUnixSeconds > 0 ? Date(timeIntervalSince1970: notified.askedUnixSeconds) : .now,
            state: .waitingForYou(until: Date(timeIntervalSince1970: notified.deadlineUnixSeconds))
        )
    }

    private static func notified(_ userInfo: [AnyHashable: Any]) -> Agentkeyring_V2_NotifiedRequest? {
        guard let data = userInfo[wordsKey] as? Data,
              let notified = try? Agentkeyring_V2_NotifiedRequest(serializedBytes: data), !notified.id.isEmpty else { return nil }
        return notified
    }
}
