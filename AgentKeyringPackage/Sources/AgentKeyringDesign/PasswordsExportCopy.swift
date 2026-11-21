// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Apple's own words on the screens of the Passwords app's export, as macOS
// 27 shows them, for the pictures in the "Copy your passwords" guide. Kept
// exactly as Apple writes them, so he recognises each screen.

public enum PasswordsExportCopy {
    public static let appName = "Passwords"
    public static let menus = ["File", "Edit", "View", "Window", "Help"]
    public static let fileMenu: [String?] = [
        "New Password…", "New Window", "New Shared Group…", nil,
        "Import Passwords from File…", nil,
        "Export All Items to App…", "Export All Passwords to File…", nil, "Close",
    ]
    public static let exportAllItems = "Export All Items to App…"

    public static let someItemsTitle = "Some items will not be exported."

    public static let exportTitle = "Export Passwords"

    public static let touchIDTitle = "Passwords is trying to export the selected items."
    public static let touchIDBody = "Touch ID or enter your password to continue with Passwords."
    public static let usePassword = "Use Password…"

    public static let destinationTitle = "Select a Destination"
    public static let agentKeyring = "Agent Keyring"
    public static let earlierVersion = "AgentKeyring"

    public static func confirmTitle(_ count: Int) -> String { "Export \(count.formatted()) items to “Agent Keyring”?" }
    public static func confirmBody(_ count: Int) -> String {
        let more = max(count - 2, 0)
        return "“Agent Keyring” will receive your login information for “example.com”, “mail.example” and \(more.formatted()) more. This app will be able to use the items you export to access your accounts."
    }
    public static let continueInAgentKeyring = "Continue in “Agent Keyring”"

    public static let cancel = "Cancel"
    public static let continueButton = "Continue"
}
