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

public struct CredentialImportFailure: Equatable, Sendable {
    public let diagnostic: String
    public let message: String

    public init(error: any Error, hadExistingMirror: Bool) {
        let nsError = error as NSError
        diagnostic = Self.diagnosticChain(startingAt: nsError)

        let safetySuffix = hadExistingMirror ? " Your earlier copy was not changed." : ""

        if nsError.domain == ASAuthorizationErrorDomain,
            nsError.code == ASAuthorizationError.failed.rawValue
        {
            message = "Passwords did not send your passwords. Start the export again in Passwords." + safetySuffix
        } else if nsError.domain == ASAuthorizationErrorDomain,
            nsError.code == ASAuthorizationError.credentialImport.rawValue
        {
            message = "Passwords could not finish sending your passwords. Start the export again in Passwords." + safetySuffix
        } else {
            message = "Passwords could not send your passwords. Try the export again." + safetySuffix
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
