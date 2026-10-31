import AgentKeyringPhoneApprover
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// These are device-wrapped Secure Enclave representations, not exportable private keys.
/// Approval-only v3 never reuses a key enrolled with the former generic role.
struct PhoneEnclaveKeys: PhoneApproverKeys {
    private let service = "com.joshpalmer.AgentKeyring.Phone.enclave"

    func vaultPublicKey(createIfMissing: Bool) throws -> P256.KeyAgreement.PublicKey {
        let context = LAContext()
        context.interactionNotAllowed = true
        return try agreementKey(context: context, createIfMissing: createIfMissing).publicKey
    }

    func signingPublicKey() throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = true
        return try signingKey(context: context, createIfMissing: true).publicKey.x963Representation
    }

    func authorize(_ context: LAContext, reason: String) async throws {
        context.localizedReason = reason
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), context.biometryType == .faceID else {
            throw error ?? PhoneEnclaveFailure.enclaveUnavailable
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
            throw LAError(.authenticationFailed)
        }
        // Signing must use this action's authentication. Fail instead of
        // silently presenting another Face ID prompt.
        context.interactionNotAllowed = true
    }

    /// A fresh authentication context is required for every explicit action.
    func authenticationContext(reason: String) -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        return context
    }

    func sign(_ bytes: Data, context: LAContext) throws -> Data {
        try signingKey(context: context, createIfMissing: false).signature(for: bytes).derRepresentation
    }

    private func agreementKey(context: LAContext, createIfMissing: Bool) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let representation = try load(account: "vault.v1") {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: representation, authenticationContext: context)
        }
        guard createIfMissing else { throw PhoneEnclaveFailure.vaultKeyMissing }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: faceIDAccessControl(), authenticationContext: context)
        try save(key.dataRepresentation, account: "vault.v1")
        return key
    }

    private func signingKey(context: LAContext, createIfMissing: Bool) throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let representation = try load(account: "phone-answers.v3") {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation, authenticationContext: context)
        }
        guard createIfMissing else { throw PhoneEnclaveFailure.signingKeyMissing }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: faceIDAccessControl(), authenticationContext: context)
        try save(key.dataRepresentation, account: "phone-answers.v3")
        return key
    }

    private func faceIDAccessControl() throws -> SecAccessControl {
        guard SecureEnclave.isAvailable else { throw PhoneEnclaveFailure.enclaveUnavailable }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError),
              context.biometryType == .faceID else {
            throw policyError ?? NSError(domain: "AgentKeyring.FaceID", code: 1)
        }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw error?.takeRetainedValue() as Error? ?? PhoneEnclaveFailure.accessControlUnavailable
        }
        return control
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    private func load(account: String) throws -> Data? {
        var attributes = query(account: account)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    private func save(_ representation: Data, account: String) throws {
        var attributes = query(account: account)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = representation
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

enum PhoneEnclaveFailure: Error {
    case enclaveUnavailable
    case accessControlUnavailable
    case vaultKeyMissing
    case signingKeyMissing
}
