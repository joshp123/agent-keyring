import ArgumentParser

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark a rejected login as possibly stale and ask Josh to update the copy."
    )

    @Argument(help: "The site or page URL whose login was rejected, such as example.com.")
    var site: String

    func validate() throws { _ = try normaliseWebTarget(site) }

    mutating func run() async throws {
        try await CLIClient.run(.sync(targetURL: normaliseWebTarget(site)))
    }
}
