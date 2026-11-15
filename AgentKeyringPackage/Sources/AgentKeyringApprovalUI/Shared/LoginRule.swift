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
        case .automatic: "Agents get these without asking you, for up to 30 minutes at a time."
        case .blocked: "Agents can't use these. You won't be asked."
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

/// The words on the rules window that aren't a rule's own.
public enum RulesCopy {
    public static let confirmTitle = "Confirm these rules"
    public static let confirmBody = "Agents can't use any login until you confirm."
    public static let confirmBodyAfterUnreadableRules =
        "The saved rules couldn't be checked. Review and confirm the rules below before agents can use logins."
    public static let confirmUpgradeBody =
        "Your logins and rules have been kept. Confirm them once to finish updating Agent Keyring."
    /// Only the relay's copy is behind, for example after an import or the
    /// first relay setup. The rules on this Mac are fine and in use.
    public static let confirmForOtherMachinesBody =
        "Confirm to send these logins and rules to your Mac mini, so agents on your other machines can use them. Agents on this Mac already do."
    /// RFC 0008: the mini keeps Automatic logins so it can serve them while
    /// the MacBook is shut. Added to the band once a relay is paired.
    public static let automaticStoredOnMini =
        "Logins set to Automatic are also kept on your Mac mini, with their two-factor codes. Anyone with admin rights there, agents included, can read them."
    public static let otherMachinesNeedRulesTitle = "Confirm rules for other machines"
    public static let otherMachinesNeedRulesDetail = "Your other machines need them"
    public static let confirmButton = "Confirm with Touch ID"
}
