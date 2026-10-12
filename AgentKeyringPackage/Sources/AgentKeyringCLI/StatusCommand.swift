import ArgumentParser

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how many logins are available and when they were last updated."
    )

    mutating func run() async throws {
        try await CLIClient.run(.status)
    }
}
