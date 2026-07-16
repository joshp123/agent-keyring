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
            "The default for new credentials. Agents can use usernames, but passwords and verification codes ask you first."
        case .allowAutomatically:
            "Agents can use usernames, passwords and verification codes without asking. Choose this for credentials you trust agents to use unattended."
        case .block:
            "Agents cannot use usernames, passwords or verification codes from these credentials."
        }
    }

    var sidebarDetail: LocalizedStringResource {
        switch self {
        case .ask: "Default for new credentials"
        case .allowAutomatically: "Use without asking"
        case .block: "Agents cannot use"
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
