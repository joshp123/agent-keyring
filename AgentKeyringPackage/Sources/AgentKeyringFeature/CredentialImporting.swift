import AuthenticationServices
import Foundation

public protocol CredentialImporting: Sendable {
    func importCredentials(token: UUID) async throws -> ASExportedCredentialData
}

public struct SystemCredentialImporter: CredentialImporting {
    public init() {}

    public func importCredentials(token: UUID) async throws -> ASExportedCredentialData {
        try await ASCredentialImportManager().importCredentials(token: token)
    }
}

struct CredentialImportFailure: Equatable, Sendable {
    let diagnostic: String
    let message: String

    init(error: any Error, hadExistingMirror: Bool) {
        let nsError = error as NSError
        diagnostic = Self.diagnosticChain(startingAt: nsError)

        let safetySuffix =
            hadExistingMirror
            ? " Your existing encrypted mirror was not changed."
            : " No mirror was created."

        if nsError.domain == ASAuthorizationErrorDomain,
            nsError.code == ASAuthorizationError.failed.rawValue
        {
            message =
                "Apple rejected the one-time import token. Quit any other Agent Keyring builds, then start the export again in Passwords."
                + safetySuffix
        } else if nsError.domain == ASAuthorizationErrorDomain,
            nsError.code == ASAuthorizationError.credentialImport.rawValue
        {
            message =
                "Apple Passwords could not complete the credential transfer. Start the export again in Passwords."
                + safetySuffix
        } else {
            message = "Apple Passwords could not transfer the credentials. Try the export again."
                + safetySuffix
        }
    }

    private static func diagnosticChain(startingAt error: NSError) -> String {
        var parts = ["\(error.domain)/\(error.code)"]
        var current = error
        var depth = 0

        while depth < 3, let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain)/\(underlying.code)")
            current = underlying
            depth += 1
        }
        return parts.joined(separator: " <- ")
    }
}
