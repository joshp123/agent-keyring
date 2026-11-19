// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// Writes a request's real words into its notification. The push carries
// only "A request is waiting." and the request sealed to this iPhone's
// notice key; this extension opens it and fills in the site, the agent and
// its reason (Paper, "The request": the Lock Screen), or the outcome once
// the request has ended (Paper, "Wherever you are").

import AgentKeyringApprovalUI
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        if let change = PhoneNoticeReader.proposal(content.userInfo) {
            // No Approve here: opening it shows the sheet, where Face ID approves it.
            content.threadIdentifier = change.id
            content.categoryIdentifier = ""
            if case .waitingForYou = change.state {
                content.title = PhoneCopy.ruleChangeNotificationTitle(change)
                content.body = PhoneCopy.ruleChangeNotificationBody(change)
                content.interruptionLevel = PhoneNoticeReader.level()
            } else {
                // Its outcome replaces it quietly; the Mac says what happened.
                content.title = PhoneCopy.ruleChangeTitle(change)
                content.body = PhoneCopy.outcome(change.state).1 + "."
                content.interruptionLevel = .passive
            }
            contentHandler(content); return
        }
        guard let words = PhoneNoticeReader.words(content.userInfo) else {
            content.interruptionLevel = PhoneNoticeReader.level()
            content.title = PhoneCopy.notificationFallbackTitle
            content.body = PhoneCopy.notificationFallbackBody
            contentHandler(content); return
        }
        content.threadIdentifier = words.request.id
        content.title = PhoneCopy.notificationTitle(words.request)
        if case let .waitingForYou(deadline) = words.request.state {
            content.userInfo[PhoneNotification.wordsKey] = PhoneNotification.encode(words.request, deadline: deadline)
            content.subtitle = PhoneCopy.notificationSubtitle(words.request.agent)
            content.body = PhoneCopy.notificationBody(words.request)
            content.categoryIdentifier = PhoneNotification.requestCategory
            content.interruptionLevel = PhoneNoticeReader.level()
        } else {
            content.body = PhoneCopy.outcomeBody(words.request, answeredBy: words.answeredBy)
            content.categoryIdentifier = ""
            content.interruptionLevel = .passive
        }
        contentHandler(content)
    }
}
