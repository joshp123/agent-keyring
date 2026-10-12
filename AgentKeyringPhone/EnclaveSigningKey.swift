import AgentKeyringApprovalCore
import Foundation
import Security

struct EnclaveSigningKey {
    private static let tag = Data("com.joshpalmer.AgentKeyring.Phone.approval.v1".utf8)
    private let privateKey: SecKey
    let publicKey: Data

    var fingerprint: String {
        PairingRequest.fingerprint(publicKey: publicKey)
    }

    static func loadOrCreate() throws -> Self {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: tag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecReturnRef: true
        ]
        var existingKey: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &existingKey)
        let privateKey: SecKey
        if status == errSecSuccess {
            privateKey = existingKey as! SecKey
        } else {
            guard status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            var accessError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &accessError
            ) else {
                throw accessError!.takeRetainedValue() as Error
            }
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits: 256,
                kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
                kSecPrivateKeyAttrs: [
                    kSecAttrIsPermanent: true,
                    kSecAttrApplicationTag: tag,
                    kSecAttrAccessControl: accessControl
                ]
            ]
            var creationError: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
                throw creationError!.takeRetainedValue() as Error
            }
            privateKey = key
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw PhoneApprovalFailure.publicKeyUnavailable }
        var exportError: Unmanaged<CFError>?
        guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &exportError) else {
            throw exportError!.takeRetainedValue() as Error
        }
        return Self(privateKey: privateKey, publicKey: publicBytes as Data)
    }

    func sign(_ bytes: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, .ecdsaSignatureMessageX962SHA256, bytes as CFData, &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        return signature as Data
    }
}
