// Written by AI on 2026.11.18 by model Claude Opus 5.5; split from the words'
// codec on 2026.11.27 by model claude opus 5.5, so the screens need no protobuf.
//
// The names a request's notification is known by on the iPhone and the Watch:
// its category, its three actions and the key its words travel under. The
// words themselves are encoded in AgentKeyringSealing/PhoneNotice.

import Foundation

public enum PhoneNotification {
    /// The category of a request's notification on the iPhone and the Watch.
    public static let requestCategory = "REQUEST"
    public static let approveAction = "APPROVE"
    public static let denyAction = "DENY"
    public static let denyAndExplainAction = "DENY_EXPLAIN"
    public static let wordsKey = "request"

    /// The request an outcome push (silent or passive collapse alert) says has been answered or has ended: its top-level "id".
    public static func ended(_ userInfo: [AnyHashable: Any]) -> String? {
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let isSilent = aps?["alert"] == nil
        let isPassiveOutcome = (aps?["interruption-level"] as? String) == "passive"
        guard (isSilent || isPassiveOutcome), let id = userInfo["id"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
