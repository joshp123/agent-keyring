import AgentKeyringPhoneApprover
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// These are device-wrapped Secure Enclave representations, not exportable private keys.
/// Signing and copy opening use the same action's Face ID context.
struct PhoneEnclaveKeys: PhoneApproverKeys {
    private let service = "com.joshpalmer.AgentKeyring.Phone.enclave"

    func replace() throws {
        for account in ["phone-answers.v3", "phone-copies.v1"] {
            let status = SecItemDelete(query(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        _ = try signingPublicKey()
        _ = try encryptionPublicKey()
    }

    func signingPublicKey() throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = true
        return try signingKey(context: context, createIfMissing: true).publicKey.x963Representation
    }

    func encryptionPublicKey() throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = true
        return try sealingKey(context: context, createIfMissing: true).publicKey.x963Representation
    }

    func openCopy(encapsulatedKey: Data, ciphertext: Data, associatedData: Data, context: LAContext) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: sealingKey(context: context, createIfMissing: false),
                                           ciphersuite: .P256_SHA256_AES_GCM_256,
                                           info: Data("agentkeyring.login-copy.v1".utf8), encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext, authenticating: associatedData)
    }

    private func sealingKey(context: LAContext, createIfMissing: Bool) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let representation = try load(account: "phone-copies.v1") {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: representation, authenticationContext: context)
        }
        guard createIfMissing else { throw PhoneEnclaveFailure.sealingKeyMissing }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: faceIDAccessControl(), authenticationContext: context)
        try save(key.dataRepresentation, account: "phone-copies.v1")
        return key
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

    func sign(_ bytes: Data, context: LAContext) throws -> Data {
        try signingKey(context: context, createIfMissing: false).signature(for: bytes).derRepresentation
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
    case signingKeyMissing
    case sealingKeyMissing
}
