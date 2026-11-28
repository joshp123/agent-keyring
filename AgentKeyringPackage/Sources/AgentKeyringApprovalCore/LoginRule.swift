// Written by AI on 2026.10.31 by model Claude Opus 5.5; trimmed on
// 2026.11.21 by model claude opus 5.5 to the names the Passwords tab shows.
//
// The rules a password can have. Matches Rule in
// proto/agentkeyring/v2/keyring.proto.

import Foundation

public enum LoginRule: String, CaseIterable, Hashable, Sendable {
    case ask
    case automatic
    case blocked

    public var name: String {
        switch self {
        case .ask: SharedCopy.ruleAskFirst
        case .automatic: SharedCopy.ruleAlwaysAllowed
        case .blocked: SharedCopy.ruleBlocked
        }
    }

    public var shortName: String { name }

    public var hint: String {
        switch self {
        case .ask: SharedCopy.ruleAskFirstShort
        case .automatic: SharedCopy.ruleAlwaysAllowedShort
        case .blocked: SharedCopy.ruleBlockedShort
        }
    }
}
