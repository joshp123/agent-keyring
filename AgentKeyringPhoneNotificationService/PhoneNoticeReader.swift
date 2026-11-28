// Written by AI on 2026.11.18 by model Claude Opus 5.5.

import AgentKeyringApprovalCore
import AgentKeyringSealing
import Foundation
import UserNotifications

enum PhoneNoticeReader {
    static var shared: PhoneSharedContext {
        PhoneSharedContext(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String)
    }

    /// Time Sensitive unless he turned it off or it is quiet hours (the iPhone's Settings).
    static func level() -> UNNotificationInterruptionLevel {
        PhoneNoticeDecoder.breaksThroughFocus(shared) ? .timeSensitive : .active
    }

    /// The request a push is about, and who answered it if it has ended.
    static func words(_ userInfo: [AnyHashable: Any]) -> DecodedPushNotificationRequest? {
        #if targetEnvironment(simulator)
        // The simulator has no Secure Enclave; its test pushes carry the words already opened.
        if let request = PhoneNotification.decode(userInfo) { return DecodedPushNotificationRequest(request: request, answeredBy: nil) }
        return nil
        #else
        let opener = PhoneNoticeOpener(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String)
        return PhoneNoticeDecoder.notifiedRequest(userInfo, shared: shared) { try opener.openNotice($0, deviceKeyID: $1) }
        #endif
    }

}
