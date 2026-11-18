// Written by AI on 2026.11.18 by model Claude Opus 5.5.

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import Foundation

enum PhoneNoticeReader {
    /// The request a push is about, and who answered it if it has ended.
    static func words(_ userInfo: [AnyHashable: Any]) -> (request: AccessRequest, answeredBy: String?)? {
        #if targetEnvironment(simulator)
        // The simulator has no Secure Enclave; its test pushes carry the words already opened.
        if let request = PhoneNotification.decode(userInfo) { return (request, nil) }
        return nil
        #else
        let keys = PhoneEnclaveKeys(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String)
        return PhoneRelayBackend.notifiedRequest(userInfo, directory: PhoneShared.directory) { try keys.openNotice($0, deviceKeyID: $1) }
        #endif
    }
}
