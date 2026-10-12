import AgentKeyringFeature
import ArgumentParser

@main
struct AgentKeyringCLI: AsyncParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(
        commandName: "agent-keyring",
        abstract:
            "Use imported Apple Passwords logins from the command line.",
        discussion: """
            EXAMPLES
              agent-keyring find example.com
              agent-keyring sync example.com
              agent-keyring fill password example.com
              agent-keyring acquire password example.com
              agent-keyring read REFERENCE
              agent-keyring clear REFERENCE

            EXIT CODES
              0  Success.
              1  Other errors, including blocked access or unavailable approval.
              2  \(MacOwner.firstName) declined the request.
              3  The request expired with no answer.
              4  macOS interrupted the approval prompt; retry the request.
              6  Touch ID or Apple Watch did not verify; retry the request.
              7  Access rules need \(MacOwner.firstName)'s confirmation in the app.
              8  No field is focused, or it is the wrong kind of field.
              9  The page does not match the saved site.
              10 This browser is not supported, or its page address cannot be read; use agent-browser.
              11 Accessibility permission is missing.
              12 The screen is locked.
              13 The browser, page or focused field changed; retry the request.
              64 Invalid command or arguments.
            """,
        version: installedVersion(),
        subcommands: [Find.self, Fill.self, Acquire.self, Read.self, Clear.self, Status.self, Sync.self, Install.self, AgentBrowserPlugin.self]
    ) }

    mutating func run() {
        print(
            "Agent Keyring lets local agents use imported Apple Passwords logins."
        )
        print("")
        print("Try:")
        print("  agent-keyring find example.com")
        print("  agent-keyring fill password example.com")
        print("")
        print("Run 'agent-keyring --help' for all commands.")
    }
}
