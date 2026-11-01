import AgentKeyringRelaySupport
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

extension RelayTLSIdentity {
    @MainActor public static func loadMacIdentity(service: String = "com.agentkeyring.relay-identity.v1") throws -> Self {
        let keychain = RelayKeychain(service: service)
        return try loadOrCreate(read: {
            let bytes = try keychain.read("tls")
            if let bytes { try keychain.write(bytes, account: "tls") }
            return bytes
        }, write: { try keychain.write($0, account: "tls") })
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
