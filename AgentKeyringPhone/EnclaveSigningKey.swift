import AgentKeyringApprovalCore
import Foundation

/// Compatibility with the original pairing screen. All new operations use the
/// Face ID protected v2 key; the biometric-free legacy key is never loaded.
struct EnclaveSigningKey {
    let publicKey: Data

    var fingerprint: String { PairingRequest.fingerprint(publicKey: publicKey) }

    static func loadOrCreate() throws -> Self {
        Self(publicKey: try PhoneEnclaveKeys().signingPublicKey())
    }

    func sign(_ bytes: Data) throws -> Data {
        let keys = PhoneEnclaveKeys()
        let context = keys.authenticationContext(reason: "Approve this Agent Keyring request")
        defer { context.invalidate() }
        return try keys.sign(bytes, context: context)
    }
}
