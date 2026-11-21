// Written by AI on 2026.10.31 by model Claude Opus 5.5; trimmed on
// 2026.11.21 by model claude opus 5.5 to the names the Passwords tab shows.
//
// The rules a password can have. Matches AccessRule in
// proto/agentkeyring/v1/agentkeyring.proto.

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
}
