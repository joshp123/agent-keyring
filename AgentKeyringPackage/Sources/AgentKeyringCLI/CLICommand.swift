import AgentKeyringFeature
import Foundation

enum CLICommand: Equatable {
    case status
    case sync(targetURL: String)
    case find(targetURL: String, account: String?)
    case fill(field: AgentCredentialField, targetURL: String, account: String?)
    case acquire(field: AgentCredentialField, targetURL: String, account: String?, credentialID: UUID?)

    var request: AgentBridgeRequest {
        switch self {
        case let .sync(targetURL):
            AgentBridgeRequest(action: .sync, targetURL: targetURL)
        case .status:
            AgentBridgeRequest(action: .status)
        case let .find(targetURL, account):
            AgentBridgeRequest(
                action: .resolve,
                targetURL: targetURL,
                usernameHint: account
            )
        case let .fill(field, targetURL, account):
            AgentBridgeRequest(action: .fill, targetURL: targetURL, usernameHint: account, field: field)
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
        if case .fill = self { return "fill" }
        return "acquire"
    }

    var targetURL: String {
        switch self {
        case let .sync(targetURL), let .find(targetURL, _), let .acquire(_, targetURL, _, _), let .fill(_, targetURL, _): targetURL
        case .status: "the requested site"
        }
    }

    var fieldName: String {
        switch self {
        case let .acquire(field, _, _, _), let .fill(field, _, _): field.displayName
        default: "requested field"
        }
    }

    var fieldArgument: String {
        switch self {
        case let .acquire(field, _, _, _), let .fill(field, _, _): field.argumentName
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
