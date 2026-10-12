import AgentKeyringFeature
import ArgumentParser

struct Sync: AsyncParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(
        abstract: "Mark rejected logins as possibly stale and ask \(MacOwner.firstName) to update the copy.",
        discussion: """
            Use this when a site rejects a login Agent Keyring filled. Matching logins
            are marked as possibly stale until the next successful import. \(MacOwner.firstName) gets
            an immediate notification with the Apple Passwords export instructions.

            EXIT CODES
              0  \(MacOwner.firstName) has been asked to update the copy.
              1  No matching login, no mirror, app unavailable, or notification failed.
              3  The request expired with no answer.
              64 Invalid command or arguments.
            """
    ) }

    @Argument(help: "The site or page URL whose login was rejected, such as example.com.")
    var site: String

    func validate() throws { _ = try normaliseWebTarget(site) }

    mutating func run() async throws {
        try await CLIClient.run(.sync(targetURL: normaliseWebTarget(site)))
    }
}
