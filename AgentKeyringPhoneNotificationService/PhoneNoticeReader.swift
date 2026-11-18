// Written by AI on 2026.11.18 by model Claude Opus 5.5.

import AgentKeyringApprovalUI
import Foundation

enum PhoneNoticeReader {
    /// The request a push is about, with the time it stops waiting.
    static func words(_ userInfo: [AnyHashable: Any]) -> (request: AccessRequest, deadline: Date)? {
        // The simulator's test pushes carry the words already opened.
        guard let request = PhoneNotification.decode(userInfo),
              case let .waitingForYou(deadline) = request.state else { return nil }
        return (request, deadline)
    }
}
