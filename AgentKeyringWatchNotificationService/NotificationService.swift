// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Writes a request's real words into the Watch's notification before it is
// shown, so Apple's first screen names the site, the agent and its reason.
// The push carries only "A request is waiting." and the request sealed to
// this Watch's notice key. The opened request is left in the notification
// for the app's own layout.

import AgentKeyringSealing
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        let log = KeyringDiagnosticLog.watch
        do {
            let saved = WatchKeychainStateStore().readWatchState()
            let opened = try WatchRequest.from(userInfo: content.userInfo, keys: WatchKeys(), saved: saved)
            WatchRequestDisplayCopy.fillNotificationContent(opened, into: content, breaksThroughFocus: saved.breaksThroughFocus)
            // An approval from any device arrives here as its outcome: record it in the dedicated
            // in-use store without ever writing saved.v3 (owned by the main Watch app).
            WatchKeychainStateStore().noteOutcome(opened)
            log.noteDeviceEvent("push", "named", ["request": opened.id])
        } catch {
            log.noteDeviceEvent("push", "refused", ["reason": "\(error)"])
            WatchRequestDisplayCopy.writeFallback(into: content)
        }
        contentHandler(content)
    }
}
