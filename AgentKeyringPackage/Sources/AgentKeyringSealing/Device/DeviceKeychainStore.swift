import Foundation
import LocalAuthentication
import Security

/// Private material is app-only, device-only and never synchronizes with iCloud.
@MainActor
public struct DeviceKeychainStore {
    let service: String
    let accessible: CFString
    public init(service: String, accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) {
        self.service = service
        self.accessible = accessible
    }
    public func readKeychainItem(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw DeviceKeychainError(status: status) }
        return data
    }
    public func writeKeychainItem(_ bytes: Data, account: String) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account)
            attributes[kSecValueData as String] = bytes
            attributes[kSecAttrAccessible as String] = accessible
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw DeviceKeychainError(status: added) }
        } else if status != errSecSuccess { throw DeviceKeychainError(status: status) }
    }
    public func deleteKeychainItem(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeviceKeychainError(status: status) }
    }
    /// Saves `bytes` only if nothing is saved under `account` yet; returns false, changing nothing, if something is.
    public func add(_ bytes: Data, account: String) throws -> Bool {
        var attributes = query(account)
        attributes[kSecValueData as String] = bytes
        attributes[kSecAttrAccessible as String] = accessible
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw DeviceKeychainError(status: status) }
        return true
    }
    private func query(_ account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: context]
    }
}

/// The keychain refused, in words: macOS's own sentence for the status, and the number for a bug report.
struct DeviceKeychainError: Error, LocalizedError, Sendable {
    let status: Int32
    var errorDescription: String? {
        let words = (SecCopyErrorMessageString(status, nil) as String?) ?? "an unknown keychain error"
        let reason = words.hasSuffix(".") ? String(words.dropLast()) : words
        return "macOS's keychain refused (\(reason), error \(status))."
    }
}
