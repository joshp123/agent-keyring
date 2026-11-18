// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// Writes a request's real words into its notification. The push carries
// only "A request is waiting." and the request sealed to this iPhone's
// notice key; this extension opens it and fills in the site, the agent and
// its reason (Paper, "The request": the Lock Screen).

import AgentKeyringApprovalUI
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        content.interruptionLevel = .timeSensitive
        if let words = PhoneNoticeReader.words(content.userInfo) {
            content.userInfo[PhoneNotification.wordsKey] = PhoneNotification.encode(words.request, deadline: words.deadline)
            content.title = PhoneCopy.notificationTitle(words.request)
            content.subtitle = PhoneCopy.notificationSubtitle(words.request.agent)
            content.body = PhoneCopy.notificationBody(words.request)
            content.threadIdentifier = words.request.id
            content.categoryIdentifier = PhoneNotification.requestCategory
        } else {
            content.title = PhoneCopy.notificationFallbackTitle
            content.body = PhoneCopy.notificationFallbackBody
        }
        contentHandler(content)
    }
}
