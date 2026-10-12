import ArgumentParser

@main
struct AgentKeyringCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-keyring",
        abstract:
            "Use imported Apple Passwords logins from the command line.",
        discussion: """
            EXAMPLES
              agent-keyring find example.com
              agent-keyring acquire password example.com
              agent-keyring read REFERENCE
              agent-keyring clear REFERENCE

            EXIT CODES
              0  Success.
              1  Other errors, including blocked access or unavailable approval.
              2  Josh declined the request.
              3  The request expired with no answer.
              4  macOS interrupted the approval prompt; retry the request.
              6  Touch ID or Apple Watch did not verify; retry the request.
              64 Invalid command or arguments.
            """,
        version: installedVersion(),
        subcommands: [Find.self, Acquire.self, Read.self, Clear.self, Status.self, Install.self, AgentBrowserPlugin.self]
    )

    mutating func run() {
        print(
            "Agent Keyring lets local agents use imported Apple Passwords logins."
        )
        print("")
        print("Try:")
        print("  agent-keyring find example.com")
        print("  agent-keyring acquire password example.com")
        print("")
        print("Run 'agent-keyring --help' for all commands.")
    }
}
