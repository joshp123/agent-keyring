// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The three rules a login can have, and the words and colours for them.
// Matches AccessRule in proto/agentkeyring/v1/agentkeyring.proto.

import SwiftUI

public enum LoginRule: String, CaseIterable, Hashable, Sendable {
    case ask
    case automatic
    case blocked

    public var name: String {
        switch self {
        case .ask: "Ask"
        case .automatic: "Automatic"
        case .blocked: "Blocked"
        }
    }

    /// One sentence on what the rule does. Shown above the list it filters.
    public var explanation: String {
        switch self {
        case .ask: "Agents ask you before each task. New logins start here."
        case .automatic: "Approved without asking. Still recorded, and still ends after 30 minutes."
        case .blocked: "Agents can't use these, and you aren't asked."
        }
    }

    public var symbol: String {
        switch self {
        case .ask: "questionmark.circle.fill"
        case .automatic: "checkmark.circle.fill"
        case .blocked: "minus.circle.fill"
        }
    }

    public var colour: Color {
        switch self {
        case .ask: KeyringColour.signal
        case .automatic: KeyringColour.approveText
        case .blocked: KeyringColour.denyText
        }
    }
}
