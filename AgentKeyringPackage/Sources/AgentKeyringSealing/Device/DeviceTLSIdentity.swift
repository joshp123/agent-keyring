import AgentKeyringApprovalCore
import AgentKeyringProtocol
import CryptoKit
import Foundation
import Security

public struct DeviceTLSIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let publicKeySPKI: Data
    private static let magicV2 = Data("AKRTLS02".utf8)

    public func signWithTLSKey(_ message: Data) throws -> Data {
        var key: SecKey?
        let status = SecIdentityCopyPrivateKey(identity, &key)
        guard status == errSecSuccess, let key else { throw DeviceKeychainError(status: status) }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) else {
            throw error?.takeRetainedValue() as Error? ?? DeviceKeychainError(status: errSecInternalComponent)
        }
        return signature as Data
    }

    @MainActor public static func loadOrCreate(service: String = "com.agentkeyring.relay-identity.v1") throws -> Self {
        let keychain = DeviceKeychainStore(service: service)
        return try loadOrCreate(read: { try keychain.readKeychainItem("tls") }, write: { try keychain.writeKeychainItem($0, account: "tls") })
    }

    /// The saved identity, or a new one saved. One this build cannot read is replaced; a keychain that cannot be
    /// read throws, and nothing is written over it.
    @MainActor public static func loadOrCreate(read: () throws -> Data?, write: (Data) throws -> Void) throws -> Self {
        if let bytes = try read() {
            if let stored = try? storedIdentity(bytes), let identity = try? Self(privateKey: stored.privateKey, certificate: stored.certificate) {
                return identity
            }
            #if os(macOS)
            KeyringDiagnosticLog.mac.noteDeviceEvent("tls", "undecodable, starting again")
            #else
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("tls", "undecodable, starting again")
            #endif
        }
        let key = P256.Signing.PrivateKey()
        var stored = Agentkeyring_V2_StoredDeviceTLSIdentity()
        stored.privateKey = key.x963Representation
        stored.certificate = try certificate(key)
        try write(magicV2 + (try stored.serializedData()))
        return try Self(privateKey: stored.privateKey, certificate: stored.certificate)
    }

    private static func storedIdentity(_ bytes: Data) throws -> Agentkeyring_V2_StoredDeviceTLSIdentity {
        guard bytes.starts(with: magicV2) else { throw CocoaError(.fileReadCorruptFile) }
        return try Agentkeyring_V2_StoredDeviceTLSIdentity(serializedBytes: Data(bytes.dropFirst(magicV2.count)))
    }

    /// Also used by the dummy-only process fixture with an isolated software key.
    public init(privateKey: Data, certificate: Data) throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, &error),
            let cert = SecCertificateCreateWithData(nil, certificate as CFData),
            let identity = SecIdentityCreate(nil, cert, key) else {
            throw error?.takeRetainedValue() as Error? ?? DeviceKeychainError(status: errSecInvalidKeyRef)
        }
        self.identity = identity
        publicKeySPKI = try Self.spki(certificate: cert)
    }

    /// A new identity held only in memory, never in the keychain: for tests and stand-in devices.
    public static func ephemeral() throws -> Self {
        let key = P256.Signing.PrivateKey()
        return try Self(privateKey: key.x963Representation, certificate: certificate(key))
    }

    /// The SubjectPublicKeyInfo of a P-256 certificate's key, which is what peers pin.
    public static func spki(certificate: SecCertificate) throws -> Data {
        guard let key = SecCertificateCopyKey(certificate),
            let bytes = SecKeyCopyExternalRepresentation(key, nil) as? Data,
            (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil else {
            throw AgentRPCError(.unauthenticated, MessageCopy.unacceptedKey)
        }
        return spkiPrefix + bytes
    }
    private static let spkiPrefix = Data([0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00])

    // A fixed-shape, self-signed P-256 certificate. TLS trusts its pinned SPKI,
    // not a public CA or the common name. The private key never goes to a file.
    private static func certificate(_ key: P256.Signing.PrivateKey) throws -> Data {
        func der(_ tag: UInt8, _ bytes: Data) -> Data {
            let length: [UInt8]
            if bytes.count < 128 { length = [UInt8(bytes.count)] }
            else if bytes.count < 256 { length = [0x81, UInt8(bytes.count)] }
            else { length = [0x82, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] }
            return Data([tag] + length) + bytes
        }
        func seq(_ bytes: Data) -> Data { der(0x30, bytes) }
        let algorithm = seq(Data([0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02]))
        let name = seq(der(0x31, seq(Data([0x06,0x03,0x55,0x04,0x03]) + der(0x0c, Data("Agent Keyring".utf8)))))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let validity = seq(der(0x18, Data(formatter.string(from: Date().addingTimeInterval(-60)).utf8))
            + der(0x18, Data(formatter.string(from: Date().addingTimeInterval(10 * 365 * 86400)).utf8)))
        var serialBytes = Data(SHA256.hash(data: key.publicKey.x963Representation)).prefix(16)
        serialBytes[serialBytes.startIndex] |= 0x80
        let serial = der(0x02, Data([0]) + serialBytes)
        let body = seq(der(0xa0, Data([0x02,0x01,0x02])) + serial + algorithm + name + validity + name + spkiPrefix + key.publicKey.x963Representation)
        return seq(body + algorithm + der(0x03, Data([0]) + (try key.signature(for: body).derRepresentation)))
    }
}
