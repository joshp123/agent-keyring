import AgentKeyringCredentialImport
import CryptoKit
import Foundation

struct PhoneVaultCiphertext: Codable {
    let version: Int
    let ephemeralPublicKey: Data
    let sealedLogin: Data

    static func seal(_ item: MirrorItem, to publicKey: P256.KeyAgreement.PublicKey, ciphertextID: UUID) throws -> Self {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let context = context(itemID: item.id, ciphertextID: ciphertextID)
        let box = try AES.GCM.seal(PropertyListEncoder().encode(item), using: key(sharedSecret, context: context),
                                   authenticating: context)
        return Self(version: 1, ephemeralPublicKey: ephemeral.publicKey.x963Representation, sealedLogin: box.combined!)
    }

    func open(itemID: UUID, ciphertextID: UUID,
              keyAgreement: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> MirrorItem {
        guard version == 1 else { throw PhoneVaultFailure.unsupportedVersion }
        let sharedSecret = try keyAgreement(P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey))
        let context = Self.context(itemID: itemID, ciphertextID: ciphertextID)
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedLogin),
                                    using: Self.key(sharedSecret, context: context), authenticating: context)
        return try PropertyListDecoder().decode(MirrorItem.self, from: data)
    }

    private static func context(itemID: UUID, ciphertextID: UUID) -> Data {
        Data("AgentKeyring.PhoneVault.v1/\(itemID.uuidString)/\(ciphertextID.uuidString)".utf8)
    }

    private static func key(_ sharedSecret: SharedSecret, context: Data) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("AgentKeyring.PhoneVault.v1".utf8),
                                             sharedInfo: context, outputByteCount: 32)
    }
}
