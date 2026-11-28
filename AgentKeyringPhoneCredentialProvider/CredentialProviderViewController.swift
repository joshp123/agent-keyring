// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// Registers Agent Keyring as a place Passwords can export to. It offers nothing
// to AutoFill: Passwords hands the export to the app itself, with an NSUserActivity.

import AuthenticationServices

final class CredentialProviderViewController: ASCredentialProviderViewController {}
