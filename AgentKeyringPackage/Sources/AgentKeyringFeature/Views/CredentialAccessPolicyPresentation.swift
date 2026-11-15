import SwiftUI

@available(macOS 26.0, *)
extension CredentialAccessPolicy {
    var displayName: LocalizedStringResource {
        switch self {
        case .ask: "Ask"
        case .allowAutomatically: "Automatic"
        case .block: "Blocked"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .ask:
            "Agents ask you before each task. New logins start here."
        case .allowAutomatically:
            "Agents get these without asking you, for up to 30 minutes at a time."
        case .block:
            "Agents can't use these. You won't be asked."
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
