// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// Writes a request's real words into its notification. The push carries
// only "A request is waiting." and the request sealed to this iPhone's
// notice key; this extension opens it and fills in the site, the agent and
// its reason (Paper, "The request": the Lock Screen), or the outcome once
// the request has ended (Paper, "Wherever you are").

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import AgentKeyringSealing
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
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
            // No subtitle: iOS cuts it to one line. Who asks leads the body, which wraps; the reason comes last.
            content.subtitle = ""
            content.body = words.request.isPractice ? PhoneCopy.practiceNotificationBody
                : PhoneCopy.notificationSubtitle(words.request.agent) + ".\n" + PhoneCopy.notificationBody(words.request)
            content.categoryIdentifier = PhoneNotification.requestCategory
            content.interruptionLevel = PhoneNoticeReader.level()
            // The relay hears that the request reached this iPhone.
            let id = words.request.id
            let done = UncheckedContent(handler: contentHandler, content: content)
            ArrivalNote.send(request: id, log: PhoneDiagnostics.log, { try await PhoneRelayBackend.noteArrival(id, shared: PhoneNoticeReader.shared) },
                             show: done.call)
            return
        } else {
            content.body = PhoneCopy.outcomeBody(words.request, answeredBy: words.answeredBy)
            content.categoryIdentifier = ""
            content.interruptionLevel = .passive
        }
        contentHandler(content)
    }
}

/// The content handler and the content, carried into the task that calls it once.
private struct UncheckedContent: @unchecked Sendable {
    let handler: (UNNotificationContent) -> Void
    let content: UNNotificationContent
    func call() { handler(content) }
}
