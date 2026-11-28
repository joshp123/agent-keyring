import AgentKeyringApprovalCore
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

    init(error: any Error, hadExistingVault: Bool) {
        let nsError = error as NSError
        diagnostic = Self.diagnosticChain(startingAt: nsError)

        if nsError.domain == ASAuthorizationErrorDomain,
            nsError.code == ASAuthorizationError.failed.rawValue
        {
            message = MessageCopy.exportFailed(.notSent, hadEarlierCopy: hadExistingVault)
        } else if nsError.domain == ASAuthorizationErrorDomain,
            nsError.code == ASAuthorizationError.credentialImport.rawValue
        {
            message = MessageCopy.exportFailed(.unfinished, hadEarlierCopy: hadExistingVault)
        } else {
            message = MessageCopy.exportFailed(.other, hadEarlierCopy: hadExistingVault)
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
