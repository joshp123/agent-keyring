// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The words on Apple's own notification screens, the same as the iPhone's
// Lock Screen (Paper, "The request").

#if os(watchOS)
import Foundation
import UserNotifications

public enum WatchRequestDisplayCopy {
    /// Distinct from iPhone's "REQUEST" so mirrored iPhone notifications never open Watch's custom controller.
    public static let requestCategory = "WATCH_REQUEST"
    static let fallbackTitle = "Agent Keyring"
    static let fallbackBody = "An agent wants to use a password. Open Agent Keyring to see the request."

    /// `breaksThroughFocus`: the iPhone's Settings, Time Sensitive and Quiet Hours, at this moment.
    public static func fillNotificationContent(_ request: WatchRequest, into content: UNMutableNotificationContent, breaksThroughFocus: Bool = true) {
        content.threadIdentifier = request.id
        content.title = request.site
        content.userInfo[WatchRequest.envelopeKey] = request.envelope.base64EncodedString()
        switch request.state {
        case .waiting:
            // One sentence, who is asking first; Apple cuts it at three lines.
            content.subtitle = ""
            let what = request.account.isEmpty ? request.wants + " this password" : "\(request.wants) \(request.account)"
            content.body = request.reason.isEmpty ? what + "." : "\(what): “\(request.reason)”"
            content.categoryIdentifier = requestCategory
            content.interruptionLevel = breaksThroughFocus ? .timeSensitive : .active
        case .ended(let outcome, _):
            content.subtitle = ""
            content.body = outcome
            content.categoryIdentifier = ""
            content.interruptionLevel = .passive
        }
    }

    public static func writeFallback(into content: UNMutableNotificationContent) {
        content.categoryIdentifier = ""
        content.title = fallbackTitle
        content.body = fallbackBody
    }
}
#endif
