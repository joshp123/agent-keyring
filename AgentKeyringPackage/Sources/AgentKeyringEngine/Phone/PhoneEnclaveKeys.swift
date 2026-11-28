// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's keys in its Secure Enclave. Only the Enclave's wrapped form is
// kept in the keychain; the private keys never leave the chip. A new face
// enrolled in Face ID stops the signing and opening keys working.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated public struct PhoneEnclaveKeys: PhoneDeviceKeys {
    private let service = "com.joshpalmer.AgentKeyring.Phone.keys.v2"
    /// The keychain group the app shares with its notification service extension.
    private let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    public func signingPublicKey() throws -> Data { try signingKey(LAContext.silent).publicKey.x963Representation }
    public func openingPublicKey() throws -> Data { try openingKey(LAContext.silent).publicKey.x963Representation }
    public func replyPublicKey() throws -> Data { try replyKey().publicKey.x963Representation }
    public func noticePublicKey() throws -> Data { try noticeKey().publicKey.x963Representation }

    @MainActor public func authorize(_ context: LAContext, reason: String) async throws {
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

    public func signWithDeviceKey(_ bytes: Data, context: LAContext) throws -> Data {
        try signingKey(context).signature(for: bytes).derRepresentation
    }

    public func openSealedLogin(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret {
        try CredentialSealing.openSealedLogin(sealed, with: openingKey(context))
    }

    public func signReply(_ bytes: Data) throws -> Data {
        try replyKey().signature(for: bytes).derRepresentation
    }

    public func replySigner() throws -> @Sendable (Data) throws -> Data {
        let key = UncheckedSendable(try replyKey())
        return { try key.value.signature(for: $0).derRepresentation }
    }

    public func opener(context: LAContext) throws -> @Sendable (SealedLogin) throws -> LoginSecret {
        let key = UncheckedSendable(try openingKey(context))
        return { try CredentialSealing.openSealedLogin($0, with: key.value) }
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
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false,
                                    kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// What a push shows, opened with the notice key. For the notification service extension.
    /// It runs while the phone is locked, so it uses only the notice key.
    public func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        try CredentialSealing.openNotice(notice, deviceKeyID: deviceKeyID, with: noticeKey())
    }

    public func cloudKeyOpener() throws -> CloudEnvelope.KeyOpener {
        let key = UncheckedSendable(try noticeKey())
        return { try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: key.value) }
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
#endif
