// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's keys in its Secure Enclave. Only the Enclave's wrapped form is
// kept in the keychain; the private keys never leave the chip. A new face
// enrolled in Face ID stops the signing and opening keys working.

import AgentKeyringPhoneApprover
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct PhoneEnclaveKeys: PhoneDeviceKeys {
    private let service = "com.joshpalmer.AgentKeyring.Phone.keys.v2"

    func signingPublicKey() throws -> Data { try signingKey(LAContext.silent).publicKey.x963Representation }
    func openingPublicKey() throws -> Data { try openingKey(LAContext.silent).publicKey.x963Representation }
    func replyPublicKey() throws -> Data { try replyKey().publicKey.x963Representation }
    func noticePublicKey() throws -> Data { try noticeKey().publicKey.x963Representation }

    func authorize(_ context: LAContext, reason: String) async throws {
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
                throw LAError(.authenticationFailed)
            }
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            throw CancellationError()
        }
        // Signing and opening must use this approval; never a second prompt.
        context.interactionNotAllowed = true
    }

    func sign(_ bytes: Data, context: LAContext) throws -> Data {
        try signingKey(context).signature(for: bytes).derRepresentation
    }

    func open(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret {
        try Sealing.open(sealed, with: openingKey(context))
    }

    func signReply(_ bytes: Data) throws -> Data {
        try replyKey().signature(for: bytes).derRepresentation
    }

    // MARK: Keys

    private func signingKey(_ context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        try key("signing", make: { try .init(accessControl: biometric(), authenticationContext: context) },
                load: { try .init(dataRepresentation: $0, authenticationContext: context) })
    }

    private func openingKey(_ context: LAContext) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        try key("opening", make: { try .init(accessControl: biometric(), authenticationContext: context) },
                load: { try .init(dataRepresentation: $0, authenticationContext: context) })
    }

    private func replyKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        try key("reply", make: { try .init(accessControl: unlocked(kSecAttrAccessibleWhenUnlockedThisDeviceOnly)) },
                load: { try .init(dataRepresentation: $0) })
    }

    /// Opened by the notification service extension, which runs while the phone is locked.
    private func noticeKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        try key("notice", make: { try .init(accessControl: unlocked(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)) },
                load: { try .init(dataRepresentation: $0) })
    }

    private func key<Key>(_ name: String, make: () throws -> Key, load: (Data) throws -> Key) throws -> Key
        where Key: SecureEnclaveKey {
        if let saved = try read(name) { return try load(saved) }
        let key = try make()
        try write(key.dataRepresentation, name)
        return key
    }

    private func biometric() throws -> SecAccessControl {
        try accessControl(kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet])
    }

    private func unlocked(_ accessible: CFString) throws -> SecAccessControl {
        try accessControl(accessible, [.privateKeyUsage])
    }

    private func accessControl(_ accessible: CFString, _ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, accessible, flags, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return control
    }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    private func read(_ name: String) throws -> Data? {
        var attributes = query(name)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return data
    }

    private func write(_ data: Data, _ name: String) throws {
        var attributes = query(name)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

protocol SecureEnclaveKey { var dataRepresentation: Data { get } }
extension SecureEnclave.P256.Signing.PrivateKey: SecureEnclaveKey {}
extension SecureEnclave.P256.KeyAgreement.PrivateKey: SecureEnclaveKey {}

extension LAContext {
    /// For reading a public key: never shows Face ID.
    static var silent: LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
