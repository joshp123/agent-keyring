import Foundation
import CryptoKit
import LocalAuthentication
import Security

public protocol AccessRulesSigning: Sendable {
    func sign(_ bytes: Data, reason: String) async throws -> Data
    func verify(_ signature: Data, for bytes: Data) throws -> Bool
    func signedBytesHash() throws -> Data?
}

public struct SecureEnclaveAccessRulesSigner: AccessRulesSigning {
    private let applicationTag = Data("AgentKeyring.access-rules.signing.v1".utf8)
    private let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256

    public init() {}

    public func sign(_ bytes: Data, reason: String) async throws -> Data {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        defer { context.invalidate() }
        guard try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometricsOrCompanion,
            localizedReason: reason
        ) else { throw signingError(errSecAuthFailed) }

        let key: SecKey
        do {
            key = try storedKey(context: context)
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain
            && error.code == Int(errSecItemNotFound) {
            key = try createKey(context: context)
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, bytes as CFData, &error) else {
            throw error?.takeRetainedValue() as Error? ?? signingError(errSecInternalComponent)
        }
        try storeSignedBytesHash(Data(SHA256.hash(data: bytes)))
        return signature as Data
    }

    public func signedBytesHash() throws -> Data? {
        var query = signedBytesHashQuery()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw signingError(status) }
        return result as? Data
    }

    private func storeSignedBytesHash(_ hash: Data) throws {
        let query = signedBytesHashQuery()
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: hash] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = hash
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw signingError(addStatus) }
        } else if status != errSecSuccess { throw signingError(status) }
    }

    private func signedBytesHashQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AgentKeyring.access-rules.signed-bytes.v1",
            kSecAttrAccount as String: "latest",
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func verify(_ signature: Data, for bytes: Data) throws -> Bool {
        let key = try storedKey()
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw signingError(errSecInvalidKeyRef)
        }
        return SecKeyVerifySignature(publicKey, algorithm, bytes as CFData, signature as CFData, nil)
    }

    private func storedKey(context: LAContext? = nil) throws -> SecKey {
        let lookupContext = context ?? LAContext()
        if context == nil { lookupContext.interactionNotAllowed = true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: applicationTag,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: lookupContext,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else { throw signingError(status) }
        return result as! SecKey
    }

    private func createKey(context: LAContext) throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error
        ) else {
            throw error?.takeRetainedValue() as Error? ?? signingError(errSecInternalComponent)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: applicationTag,
                kSecAttrAccessControl as String: accessControl,
            ],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? signingError(errSecInternalComponent)
        }
        return key
    }

    private func signingError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
