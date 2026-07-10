import SwiftUI

@available(macOS 26.0, *)
extension CredentialAccessPolicy {
    var displayName: LocalizedStringResource {
        switch self {
        case .ask: "Ask each time"
        case .allowAutomatically: "Allow automatically"
        case .block: "Blocked"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .ask:
            "Passwords and verification codes need Touch ID or Apple Watch. Usernames remain available."
        case .allowAutomatically:
            "No confirmation is shown. Any local process running as your macOS user can copy these credentials."
        case .block:
            "Local agents cannot copy usernames, passwords or verification codes from these credentials."
        }
    }

    var sidebarDetail: LocalizedStringResource {
        switch self {
        case .ask: "Confirm secret access"
        case .allowAutomatically: "No confirmation"
        case .block: "No agent access"
        }
    }

    var symbol: String {
        switch self {
        case .ask: "applewatch"
        case .allowAutomatically: "checkmark.circle.fill"
        case .block: "nosign"
        }
    }

    var colour: Color {
        switch self {
        case .ask: .blue
        case .allowAutomatically: .green
        case .block: .red
        }
    }
}
