import AgentKeyringFeature
import ArgumentParser
import Foundation

struct CLIError: Error {
    let message: String
    let suggestion: String?
    let exitCode: Int32

    init(_ message: String, suggestion: String? = nil, exitCode: Int32 = 1) {
        self.message = message
        self.suggestion = suggestion
        self.exitCode = exitCode
    }

    init(response: AgentBridgeResponse, command: CLICommand) {
        let targetURL = command.targetURL
        switch response.error {
        case .notFound:
            self.init(
                "No login matches \(displayHost(targetURL)).",
                suggestion: "Check the URL, or update Agent Keyring from Apple Passwords."
            )
        case .ambiguous:
            let accounts = response.candidates?.compactMap(\.username) ?? []
            let choices = accounts.map { "  \($0)" }.joined(separator: "\n")
            let suggestion: String
            let uniqueAccounts = Set(accounts.map { $0.lowercased() })
            if uniqueAccounts.count < accounts.count {
                suggestion =
                    "Run 'agent-keyring find \(targetURL)' to see the credential IDs, then choose one:\nagent-keyring \(command.releaseVerb) \(command.fieldArgument) \(shellQuote(targetURL)) --credential UUID"
            } else if let account = accounts.first {
                suggestion =
                    "Choose an account:\n\(choices)\nTry: agent-keyring \(command.releaseVerb) \(command.fieldArgument) \(shellQuote(targetURL)) --account \(shellQuote(account))"
            } else {
                suggestion = "Run 'agent-keyring find \(targetURL)' and choose a credential."
            }
            self.init(
                "More than one login matches \(displayHost(targetURL)).",
                suggestion: suggestion
            )
        case .fieldUnavailable:
            self.init("That login has no \(command.fieldName) available.")
        case .insecureOrigin:
            self.init(
                "Agent Keyring will not release credentials to an insecure page.",
                suggestion: "Use the HTTPS page instead."
            )
        case .invalidURL:
            self.init(
                "'\(targetURL)' is not a valid site or page URL.",
                suggestion: "Use a site such as example.com."
            )
        case .mirrorUnavailable:
            self.init(
                "No logins are available yet.",
                suggestion: "Open Agent Keyring and import them from Apple Passwords."
            )
        case .authorizationDenied:
            self.init("Josh declined the request.", exitCode: 2)
        case .authorizationNotVerified:
            self.init("Touch ID or Apple Watch did not verify; retry the request.", exitCode: 6)
        case .authorizationInterrupted:
            self.init("macOS interrupted the approval prompt; retry the request.", exitCode: 4)
        case .authorizationUnavailable:
            self.init(
                response.message ?? "Credential approval is not available. Nothing was released."
            )
        case .policyDenied:
            self.init("Access to this login is blocked in Agent Keyring. Nothing was released.")
        case .requestExpired, .timedOut:
            self.init("The request expired with no answer.", exitCode: 3)
        case .invalidTOTP:
            self.init(
                "Agent Keyring could not create a verification code for this login.",
                suggestion: "Update Agent Keyring from Apple Passwords, then try again."
            )
        case .bridgeUnavailable, .internalError, .invalidRequest, .approvalPending, .rulesNeedConfirmation, .none:
            self.init(
                response.message ?? "Agent Keyring could not complete the request.",
                suggestion: "Open the app and try again."
            )
        }
    }

    var rendered: String {
        message + "\n" + (suggestion.map { $0 + "\n" } ?? "")
    }

    static let unavailable = CLIError(
        "Agent Keyring could not be reached.",
        suggestion: "Open the app and try again."
    )
    static let invalidResponse = CLIError(
        "Agent Keyring returned an incomplete response.",
        suggestion: "Open the app and try again."
    )
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func stop(_ error: CLIError, diagnostics: FileHandle = .standardError) throws -> Never {
    write(error.rendered, to: diagnostics)
    throw ExitCode(error.exitCode)
}

func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}
