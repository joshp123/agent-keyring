import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Private material is app-only, device-only and never synchronizes with iCloud.
@MainActor
struct RelayKeychain {
    let service: String
    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw KeychainError(status: status) }
        return data
    }
    func write(_ bytes: Data, account: String) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account)
            attributes[kSecValueData as String] = bytes
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    private func query(_ account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: context]
    }
}

public struct RelayTLSIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let publicKeySPKI: Data
    private struct Saved: Codable { let privateKey: Data; let certificate: Data }

    @MainActor public static func loadOrCreate(service: String = "com.agentkeyring.relay-identity.v1") throws -> Self {
        let keychain = RelayKeychain(service: service)
        let saved: Saved
        if let bytes = try keychain.read("tls") {
            saved = try PropertyListDecoder().decode(Saved.self, from: bytes)
            try keychain.write(bytes, account: "tls")
        }
        else {
            let key = P256.Signing.PrivateKey()
            saved = Saved(privateKey: key.x963Representation, certificate: try certificate(key))
            try keychain.write(PropertyListEncoder().encode(saved), account: "tls")
        }
        return try Self(privateKey: saved.privateKey, certificate: saved.certificate)
    }

    /// Also used by the dummy-only process fixture with an isolated software key.
    public init(privateKey: Data, certificate: Data) throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, &error),
            let cert = SecCertificateCreateWithData(nil, certificate as CFData),
            let identity = SecIdentityCreate(nil, cert, key) else {
            throw error?.takeRetainedValue() as Error? ?? KeychainError(status: errSecInvalidKeyRef)
        }
        self.identity = identity
        publicKeySPKI = try Self.spki(certificate: cert)
    }

    static func spki(certificate: SecCertificate) throws -> Data {
        guard let key = SecCertificateCopyKey(certificate),
            let bytes = SecKeyCopyExternalRepresentation(key, nil) as? Data,
            (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil else {
            throw LeaseFailure(.unauthenticated, "The relay must use a P-256 TLS identity.")
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

@MainActor
public protocol RelayApproverSigning {
    var publicKey: Data { get }
    var automaticPublicKey: Data { get }
    func authorize(context: LAContext, reason: String) async throws
    func sign(_ bytes: Data, context: LAContext?, automatic: Bool) throws -> Data
}

@MainActor
public final class SecureEnclaveRelaySigner: RelayApproverSigning {
    private let humanKey: Data
    private let automaticKey: Data
    private let humanAccess: SecAccessControl
    public let publicKey: Data
    public let automaticPublicKey: Data

    public init(service: String = "com.agentkeyring.relay-signing.v1") throws {
        guard SecureEnclave.isAvailable else { throw CredentialReleaseAuthorizationError.unavailable }
        let keychain = RelayKeychain(service: service)
        func access(_ flags: SecAccessControlCreateFlags, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws -> SecAccessControl {
            var error: Unmanaged<CFError>?
            guard let value = SecAccessControlCreateWithFlags(nil, accessibility, flags, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return value
        }
        humanAccess = try access([.privateKeyUsage, .biometryAny])
        func load(_ account: String, control: SecAccessControl) throws -> SecureEnclave.P256.Signing.PrivateKey {
            if let bytes = try keychain.read(account) {
                // The wrapper may be read while locked; the enclave key's own
                // access control still governs every private-key operation.
                try keychain.write(bytes, account: account)
                return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: bytes)
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: control)
            try keychain.write(key.dataRepresentation, account: account)
            return key
        }
        let human = try load("human", control: humanAccess)
        let automatic = try load("delivery-after-first-unlock.v1", control: access(.privateKeyUsage, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly))
        humanKey = human.dataRepresentation
        automaticKey = automatic.dataRepresentation
        publicKey = human.publicKey.x963Representation
        automaticPublicKey = automatic.publicKey.x963Representation
    }

    public func authorize(context: LAContext, reason: String) async throws {
        try Task.checkCancellation()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        context.localizedReason = reason
        let cancel: @MainActor @Sendable () -> Void = { context.invalidate() }
        do {
            let authorized = try await withTaskCancellationHandler {
                try await context.evaluateAccessControl(humanAccess, operation: .useKeySign, localizedReason: reason)
            } onCancel: { Task { @MainActor in cancel() } }
            try Task.checkCancellation()
            guard authorized else { throw CredentialReleaseAuthorizationError.notVerified }
            // A signature may reuse this authorization, never open a second prompt.
            context.interactionNotAllowed = true
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    public func sign(_ bytes: Data, context: LAContext?, automatic: Bool) throws -> Data {
        if automatic {
            let silent = LAContext()
            silent.interactionNotAllowed = true
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: automaticKey, authenticationContext: silent)
                .signature(for: bytes).derRepresentation
        }
        guard let context else { throw CredentialReleaseAuthorizationError.notVerified }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: humanKey, authenticationContext: context)
            .signature(for: bytes).derRepresentation
    }
}
