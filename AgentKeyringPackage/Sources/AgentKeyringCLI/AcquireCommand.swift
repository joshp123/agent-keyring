import AgentKeyringFeature
import ArgumentParser
import Foundation

struct Acquire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Retain one credential field for 5 minutes; print its reference.",
        discussion: "Clear the reference when entry succeeds or you abandon the task. Values expire after 5 minutes."
    )

    @Argument(help: "The field to acquire: username, password or code.") var field: CredentialFieldArgument
    @Argument(help: "The site or page URL, such as example.com.") var site: String
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
        try await CLIClient.run(.acquire(
            field: field.bridgeField, targetURL: normaliseSecureWebTarget(site),
            account: account, credentialID: credential.flatMap(UUID.init(uuidString:))
        ))
    }
}

enum CredentialFieldArgument: String, CaseIterable, ExpressibleByArgument {
    case username
    case password
    case code

    var bridgeField: AgentCredentialField {
        switch self {
        case .username: .username
        case .password: .password
        case .code: .totp
        }
    }
}
