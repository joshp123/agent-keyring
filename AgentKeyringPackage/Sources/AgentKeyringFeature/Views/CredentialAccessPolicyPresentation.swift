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
            "Agents ask before using a password or verification code. This is the default for new logins."
        case .allowAutomatically:
            "Agents can use these logins without asking."
        case .block:
            "Agents cannot use these logins."
        }
    }

    var sidebarDetail: LocalizedStringResource? {
        switch self {
        case .ask: "Default"
        case .allowAutomatically, .block: nil
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
