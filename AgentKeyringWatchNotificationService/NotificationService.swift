// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Writes a request's real words into the Watch's notification before it is
// shown, so Apple's first screen names the site, the agent and its reason.
// The push carries only "A request is waiting." and the request sealed to
// this Watch's notice key. The opened request is left in the notification
// for the app's own layout.

import AgentKeyringSealing
import AgentKeyringWatchCore
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        do {
            let saved = WatchStore().read()
            let opened = try WatchRequest.from(userInfo: content.userInfo, keys: WatchKeys(), saved: saved)
            WatchWords.write(opened, into: content, breaksThroughFocus: saved.breaksThroughFocus)
            // An approval from any device arrives here as its outcome: it is in use until it ends.
            let noted = saved.noting(opened)
            if noted != saved { WatchStore().write(noted) }
            DeviceLog(device: "watch-notice").note("push", "named", ["request": opened.id])
        } catch {
            DeviceLog(device: "watch-notice").note("push", "refused", ["reason": "\(error)"])
            WatchWords.writeFallback(into: content)
        }
        contentHandler(content)
    }
}
