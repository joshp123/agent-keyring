// Written by AI on 2026.11.28 by model claude opus 5.5.
//
// The one invitation every device of the user's reads and writes in iCloud
// Keychain: a Mac or iPhone holding the lists leaves it, and a new Mac or
// iPhone follows it to join through iCloud. Only Agent Keyring's own apps,
// in its shared keychain group, can read it. Tests and test peers hand in a
// store of their own.

import AgentKeyringProtocol
import Foundation
import Security

public struct CloudKeychainInvitationStore: Sendable {
    public let read: @MainActor @Sendable () -> Agentkeyring_V2_JoinInvite?
    /// True when the invitation was left.
    public let write: @MainActor @Sendable (Agentkeyring_V2_JoinInvite) -> Bool
    public let remove: @MainActor @Sendable () -> Void

    public init(
        read: @escaping @MainActor @Sendable () -> Agentkeyring_V2_JoinInvite?,
        write: @escaping @MainActor @Sendable (Agentkeyring_V2_JoinInvite) -> Bool,
        remove: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    /// The item in iCloud Keychain, in the app's shared keychain group (`accessGroup`, from its Info.plist).
    static func iCloudKeychain(accessGroup: String) -> CloudKeychainInvitationStore {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true, kSecAttrAccessGroup as String: accessGroup,
            kSecAttrService as String: "com.joshpalmer.AgentKeyring.invitation", kSecAttrAccount as String: "relay",
        ]
        let item = InvitationKeychainQuery(query: query)
        return CloudKeychainInvitationStore(read: {
            var found: CFTypeRef?
            var reading = item.query
            reading[kSecReturnData as String] = true
            guard SecItemCopyMatching(reading as CFDictionary, &found) == errSecSuccess, let bytes = found as? Data else { return nil }
            return try? Agentkeyring_V2_JoinInvite(serializedBytes: bytes)
        }, write: { invite in
            guard let value = try? invite.serializedData() else { return false }
            SecItemDelete(item.query as CFDictionary)
            var adding = item.query
            adding[kSecValueData as String] = value
            adding[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(adding as CFDictionary, nil) == errSecSuccess
        }, remove: {
            SecItemDelete(item.query as CFDictionary)
        })
    }

    /// No invitation is ever read or left: tests, and devices that must not touch iCloud Keychain.
    public static let nowhere = CloudKeychainInvitationStore(read: { nil }, write: { _ in false })

    /// Reads `invite` and leaves nothing: a test peer following another device's invitation.
    public static func followingInvite(_ invite: @escaping @MainActor @Sendable () -> Agentkeyring_V2_JoinInvite?) -> CloudKeychainInvitationStore {
        CloudKeychainInvitationStore(read: invite, write: { _ in false })
    }
}

/// The keychain query naming the invitation item, held so the store's closures can share it across actors.
private struct InvitationKeychainQuery: @unchecked Sendable {
    let query: [String: Any]
}
