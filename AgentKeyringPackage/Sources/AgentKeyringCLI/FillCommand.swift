import AgentKeyringFeature
import ArgumentParser
import Foundation

struct Fill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fill the focused browser field without revealing its value.",
        discussion: """
            Focus a username, secure password or code field in Safari, Chrome, Claude's pane or Codex's browser.
            The visible page must match the saved site. Agent Keyring never presses Return.
            If the page address cannot be read, use agent-browser.

            EXIT CODES
              0  Filled.
              1  Other errors, including blocked access or unavailable approval.
              2  Josh declined the request.
              3  The request expired with no answer.
              4  macOS interrupted the approval prompt; retry the request.
              6  Touch ID or Apple Watch did not verify; retry the request.
              7  Access rules need Josh's confirmation in the app.
              8  No field is focused, or it is the wrong kind of field.
              9  The page does not match the saved site.
              10 This browser is not supported, or its page address cannot be read; use agent-browser.
              11 Accessibility permission is missing.
              12 The screen is locked.
              13 The browser, page or focused field changed; retry the request.
              64 Invalid command or arguments.
            """
    )

    @Argument(help: "The field to fill: username, password or code.") var field: CredentialFieldArgument
    @Argument(help: "The saved site or page URL, such as example.com.") var site: String
    @Option(help: "Choose an account when several logins match.") var account: String?

    @Option(help: "Choose a credential ID shown by find.") var credential: String?

    func validate() throws {
        _ = try normaliseSecureWebTarget(site)
        guard account == nil || credential == nil else {
            throw ValidationError("Choose either --account or --credential.")
        }
        if let credential, UUID(uuidString: credential) == nil {
            throw ValidationError("A valid credential ID is required.")
        }
    }

    mutating func run() async throws {
        try await CLIClient.run(.fill(field: field.bridgeField,
            targetURL: normaliseSecureWebTarget(site), account: account,
            credentialID: credential.flatMap(UUID.init(uuidString:))))
    }
}
