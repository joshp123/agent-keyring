// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The Watch's four keys. On a Watch they live in its Secure Enclave and the
// keychain holds only their wrapped form. The Watch has no face or finger
// check, so every key is usable only while the Watch is unlocked: Apple's
// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on the key's own access
// control, which the chip enforces. With Wrist Detection on, the Watch locks
// when it leaves the wrist, so off the wrist the keys stop working. That last
// step is Apple's behaviour of the Watch, not something this code can check;
// the self-test reports what the Watch says about itself.
//
// The notice key is the exception: it opens only what a push shows, so it
// works after the first unlock, for the notification service extension.
//
// The simulator has no Secure Enclave; it keeps software keys instead.

#if os(watchOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import Security

public struct WatchKeys: Sendable {
    public static let service = "com.joshpalmer.AgentKeyring.Watch.keys.v2"
    /// The keychain group the app shares with its notification service extension.
    let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    public init() {
        self.init(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String)
    }

    public func signingPublicKey() throws -> Data { try signing().publicKeyBytes }
    public func openingPublicKey() throws -> Data { try opening().publicKeyBytes }
    public func replyPublicKey() throws -> Data { try reply().publicKeyBytes }
    public func noticePublicKey() throws -> Data { try notice().publicKeyBytes }
    public func keyID() throws -> String { Sealing.keyID(try signingPublicKey()) }

    public func sign(_ bytes: Data) throws -> Data { try signing().sign(bytes) }
    public func signReply(_ bytes: Data) throws -> Data { try reply().sign(bytes) }
    public func open(_ sealed: SealedLogin) throws -> LoginSecret { try opening().open(sealed) }
    public func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_Work {
        try self.notice().openNotice(notice, deviceKeyID: deviceKeyID)
    }

    /// This Watch as Members lists it.
    public func device() throws -> Agentkeyring_V2_Device {
        var device = Agentkeyring_V2_Device()
        device.signingPublicKey = try signingPublicKey()
        device.keyID = Sealing.keyID(device.signingPublicKey)
        device.kind = .watch
        device.label = "Apple Watch"
        device.openingPublicKey = try openingPublicKey()
        device.replyPublicKey = try replyPublicKey()
        device.replyKeyID = Sealing.keyID(device.replyPublicKey)
        return device
    }

    // MARK: Keys

    private func signing() throws -> SigningKey { try signingKey("signing", whenUnlocked: true) }
    private func reply() throws -> SigningKey { try signingKey("reply", whenUnlocked: true) }
    private func opening() throws -> AgreementKey { try agreementKey("opening", whenUnlocked: true) }
    private func notice() throws -> AgreementKey { try agreementKey("notice", whenUnlocked: false) }

    #if targetEnvironment(simulator)
    private func signingKey(_ name: String, whenUnlocked: Bool) throws -> SigningKey {
        let data = try stored(name) { P256.Signing.PrivateKey().rawRepresentation }
        return .software(try P256.Signing.PrivateKey(rawRepresentation: data))
    }
    private func agreementKey(_ name: String, whenUnlocked: Bool) throws -> AgreementKey {
        let data = try stored(name) { P256.KeyAgreement.PrivateKey().rawRepresentation }
        return .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: data))
    }
    #else
    private func signingKey(_ name: String, whenUnlocked: Bool) throws -> SigningKey {
        let data = try stored(name) { try SecureEnclave.P256.Signing.PrivateKey(accessControl: access(whenUnlocked)).dataRepresentation }
        return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data))
    }
    private func agreementKey(_ name: String, whenUnlocked: Bool) throws -> AgreementKey {
        let data = try stored(name) { try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access(whenUnlocked)).dataRepresentation }
        return .enclave(try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data))
    }
    private func access(_ whenUnlocked: Bool) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        let protection = whenUnlocked ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard let access = SecAccessControlCreateWithFlags(nil, protection, .privateKeyUsage, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return access
    }
    #endif

    /// The keychain item holds the key's wrapped form and stays readable after
    /// the first unlock, so a locked Watch fails at the chip, not here.
    private func stored(_ name: String, make: () throws -> Data) throws -> Data {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: name, kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var copy = query
        copy[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(copy as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        guard status == errSecItemNotFound else { throw WatchFailure.keychain(status) }
        let data = try make()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw WatchFailure.keychain(added) }
        return data
    }
}

enum SigningKey {
    case software(P256.Signing.PrivateKey)
    #if !targetEnvironment(simulator)
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    #endif

    var publicKeyBytes: Data {
        switch self {
        case .software(let key): key.publicKey.x963Representation
        #if !targetEnvironment(simulator)
        case .enclave(let key): key.publicKey.x963Representation
        #endif
        }
    }

    func sign(_ bytes: Data) throws -> Data {
        switch self {
        case .software(let key): try key.signature(for: bytes).derRepresentation
        #if !targetEnvironment(simulator)
        case .enclave(let key): try key.signature(for: bytes).derRepresentation
        #endif
        }
    }
}

enum AgreementKey {
    case software(P256.KeyAgreement.PrivateKey)
    #if !targetEnvironment(simulator)
    case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
    #endif

    var publicKeyBytes: Data {
        switch self {
        case .software(let key): key.publicKey.x963Representation
        #if !targetEnvironment(simulator)
        case .enclave(let key): key.publicKey.x963Representation
        #endif
        }
    }

    func open(_ sealed: SealedLogin) throws -> LoginSecret {
        switch self {
        case .software(let key): try Sealing.open(sealed, with: key)
        #if !targetEnvironment(simulator)
        case .enclave(let key): try Sealing.open(sealed, with: key)
        #endif
        }
    }

    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_Work {
        switch self {
        case .software(let key): try Sealing.openNotice(notice, deviceKeyID: deviceKeyID, with: key)
        #if !targetEnvironment(simulator)
        case .enclave(let key): try Sealing.openNotice(notice, deviceKeyID: deviceKeyID, with: key)
        #endif
        }
    }
}

public enum WatchFailure: Error, CustomStringConvertible, Sendable {
    case keychain(OSStatus)
    case notSetUp, unknownMachine, notInRequest, refused(String), noAnswerAddress

    public var description: String {
        switch self {
        case .keychain(let status): "keychain error \(status)"
        case .notSetUp: "the iPhone has not added this Watch yet"
        case .unknownMachine: "the asking machine is not in Members"
        case .notInRequest: "the push carried no login for this Watch"
        case .refused(let words): "the asking computer refused it: \(words)"
        case .noAnswerAddress: "the request names no door to answer at"
        }
    }
}
#endif
