import SwiftUI

@available(macOS 26.0, *)
extension CredentialAccessPolicy {
    var displayName: LocalizedStringResource {
        switch self {
        case .ask: "Ask"
        case .askOnPhone: "Ask on iPhone or Watch"
        case .allowAutomatically: "Automatic"
        case .block: "Blocked"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .ask:
            "Agents ask you before each task. New logins start here."
        case .askOnPhone:
            "Agents ask every time. Only your iPhone or Watch can approve."
        case .allowAutomatically:
            "Agents get these without asking you, for up to 30 minutes at a time."
        case .block:
            "Agents can't use these. You won't be asked."
        }
    }

    var sidebarDetail: LocalizedStringResource? {
        switch self {
        case .ask: "Default"
        case .askOnPhone, .allowAutomatically, .block: nil
        }
    }

    var symbol: String {
        switch self {
        case .ask: "applewatch"
        case .askOnPhone: "iphone"
        case .allowAutomatically: "checkmark.circle.fill"
        case .block: "nosign"
        }
    }

    var colour: Color {
        switch self {
        case .ask, .askOnPhone: .blue
        case .allowAutomatically: .green
        case .block: .red
        }
    }
}
