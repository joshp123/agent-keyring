import AgentKeyringProtocol
import CryptoKit
import Foundation

/// The byte formats in internal/relaycrypto. Sign and hash the original bytes;
/// protobuf serialization is deliberately not treated as canonical.
public enum RelayCrypto {
    public static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    public static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    public static func keyID(_ x963: Data) -> String { hex(hash(x963)) }
    public static func digest(_ domain: String, _ bytes: Data) -> Data { hash(Data((domain + "\0").utf8) + bytes) }

    public static func transcript(_ parts: [Data]) -> Data {
        var bytes = Data()
        for part in parts {
            var count = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(part)
        }
        return bytes
    }

    public static func pairTranscript(relaySPKI: Data, approverSPKI: Data, signingKey: Data, keySet: Data) -> Data {
        transcript([Data("agentkeyring.pair.v1\0".utf8), relaySPKI, approverSPKI, signingKey, keySet])
    }

    public static func enrolTranscript(relaySPKI: Data, clientSPKI: Data, receiverKey: Data, keySet: Data) -> Data {
        transcript([Data("agentkeyring.enrol.v1\0".utf8), relaySPKI, clientSPKI, receiverKey, keySet])
    }

    public static func fingerprint(_ transcript: Data) -> String {
        let encoded = hex(hash(transcript).prefix(16)).uppercased()
        return stride(from: 0, to: encoded.count, by: 4).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            return String(encoded[start..<encoded.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    public static func verify(signature: Data, statement: Data, publicKey: Data) throws -> Bool {
        try P256.Signing.PublicKey(x963Representation: publicKey)
            .isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: statement)
    }

    public static func seal(_ contents: Agentkeyring_V1_BundleContents, receiverKey: Data,
        requestDigest: Data) throws -> Agentkeyring_V1_SealedBundle {
        let key = try P256.KeyAgreement.PublicKey(x963Representation: receiverKey)
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .P256_SHA256_AES_GCM_256,
            info: Data("agentkeyring.bundle.v1".utf8))
        var plaintext = try contents.serializedData()
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        var bundle = Agentkeyring_V1_SealedBundle()
        bundle.encapsulatedKey = sender.encapsulatedKey
        bundle.ciphertext = try sender.seal(plaintext, authenticating: requestDigest)
        bundle.receiverKeyID = keyID(receiverKey)
        return bundle
    }

}
