// Written by AI on 2026.11.18 by model Claude Opus 5.5.

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import Foundation
import UserNotifications

enum PhoneNoticeReader {
    static var shared: PhoneSharedContext {
        PhoneSharedContext(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String)
    }

    /// Time Sensitive unless he turned it off or it is quiet hours (the iPhone's Settings).
    static func level() -> UNNotificationInterruptionLevel {
        PhoneRelayBackend.breaksThroughFocus(shared) ? .timeSensitive : .active
    }

    /// The request a push is about, and who answered it if it has ended.
    static func words(_ userInfo: [AnyHashable: Any]) -> PhoneRelayBackend.PhoneNotified? {
        #if targetEnvironment(simulator)
        // The simulator has no Secure Enclave; its test pushes carry the words already opened.
        if let request = PhoneNotification.decode(userInfo) { return PhoneRelayBackend.PhoneNotified(request: request, answeredBy: nil, door: nil) }
        return nil
        #else
        let keys = PhoneEnclaveKeys(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String)
        return PhoneRelayBackend.notifiedRequest(userInfo, shared: shared) { try keys.openNotice($0, deviceKeyID: $1) }
        #endif
    }

}
