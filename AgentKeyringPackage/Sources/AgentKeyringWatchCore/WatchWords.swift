// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The words on Apple's own notification screens, the same as the iPhone's
// Lock Screen (Paper, "The request").

#if os(watchOS)
import Foundation
import UserNotifications

public enum WatchWords {
    public static let requestCategory = "REQUEST"
    public static let denyAndExplain = "deny-and-explain"
    public static let fallbackTitle = "An agent is asking to use a login"
    public static let fallbackBody = "Raise your wrist to see the request."

    public static func write(_ request: WatchRequest, into content: UNMutableNotificationContent) {
        content.threadIdentifier = request.id
        content.title = request.site
        content.userInfo[WatchRequest.workKey] = request.work.base64EncodedString()
        switch request.state {
        case .waiting:
            content.subtitle = request.wants + " this login"
            content.body = [request.account, request.reason.isEmpty ? nil : "“\(request.reason)”"]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            content.categoryIdentifier = requestCategory
            content.interruptionLevel = .timeSensitive
        case .ended(let outcome):
            content.subtitle = ""
            content.body = outcome
            content.categoryIdentifier = ""
            content.interruptionLevel = .passive
        }
    }

    public static func writeFallback(into content: UNMutableNotificationContent) {
        content.title = fallbackTitle
        content.body = fallbackBody
    }
}
#endif
