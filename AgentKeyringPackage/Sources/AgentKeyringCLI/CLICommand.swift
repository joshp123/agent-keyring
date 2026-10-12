import AgentKeyringFeature
import Foundation

enum CLICommand: Equatable {
    case status
    case find(targetURL: String, account: String?)
    case acquire(field: AgentCredentialField, targetURL: String, account: String?, credentialID: UUID?)

    var request: AgentBridgeRequest {
        switch self {
        case .status:
            AgentBridgeRequest(action: .status)
        case let .find(targetURL, account):
            AgentBridgeRequest(
                action: .resolve,
                targetURL: targetURL,
                usernameHint: account
            )
        case let .acquire(field, targetURL, account, credentialID):
            AgentBridgeRequest(
                action: .acquire, targetURL: targetURL, usernameHint: account,
                candidateID: credentialID, field: field
            )

        }
    }
}

extension CLICommand {
    var releaseVerb: String {
        return "acquire"
    }

    var targetURL: String {
        switch self {
        case let .find(targetURL, _), let .acquire(_, targetURL, _, _): targetURL
        case .status: "the requested site"
        }
    }

    var fieldName: String {
        switch self {
        case let .acquire(field, _, _, _): field.displayName
        default: "requested field"
        }
    }

    var fieldArgument: String {
        switch self {
        case let .acquire(field, _, _, _): field.argumentName
        default: "password"
        }
    }
}

extension AgentCredentialField {
    var displayName: String {
        switch self {
        case .username: "username"
        case .password: "password"
        case .totp: "verification code"
        }
    }

    var argumentName: String {
        switch self {
        case .username: "username"
        case .password: "password"
        case .totp: "code"
        }
    }
}
