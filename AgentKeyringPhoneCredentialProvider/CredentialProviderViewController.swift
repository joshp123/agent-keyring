import AuthenticationServices

// Credential exchange launches the containing app with an NSUserActivity.
// This extension registers the destination; it does not receive the secrets.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.credentialIdentityNotFound.rawValue
        ))
    }
}
