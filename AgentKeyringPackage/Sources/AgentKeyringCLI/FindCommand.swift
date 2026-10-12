import ArgumentParser

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show logins that match a site without requesting a secret."
    )

    @Argument(help: "The site or page URL, such as example.com.")
    var site: String

    @Option(help: "Only show this account.")
    var account: String?

    func validate() throws {
        _ = try normaliseWebTarget(site)
    }

    mutating func run() async throws {
        try await CLIClient.run(
            .find(targetURL: normaliseWebTarget(site), account: account)
        )
    }
}
