// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// What the iPhone hands the Watch, kept in one keychain item the app shares
// with its notification service extension: the signed Members (who may ask,
// and the relay's key), the signed Catalogue (the logins' names and sites),
// and where the relay takes the Watch's answers.

#if os(watchOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Security

public struct WatchSaved: Codable, Sendable, Equatable {
    public var members: Data?
    public var catalogue: Data?
    public var answerURL: String?

    public init(members: Data? = nil, catalogue: Data? = nil, answerURL: String? = nil) {
        self.members = members; self.catalogue = catalogue; self.answerURL = answerURL
    }

    public var signedMembers: Members? {
        members.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Members(serializedBytes: $0.payload) }
    }

    public var signedCatalogue: Catalogue? {
        catalogue.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Catalogue(serializedBytes: $0.payload) }
    }

    /// The Watch is set up once a Members the iPhone signed lists it.
    public func lists(_ keyID: String) -> Bool { signedMembers?.devices.contains { $0.keyID == keyID } ?? false }

    /// Takes what the iPhone sent, keeping only a Members newer than ours and
    /// signed by a device ours lists.
    public func merging(members newMembers: Data?, catalogue newCatalogue: Data?, answerURL newURL: String?) -> WatchSaved {
        var next = self
        if let newMembers, let document = try? SignedDocument(serializedBytes: newMembers),
           (try? Sealing.verifiedMembers(document, current: signedMembers)) != nil {
            next.members = newMembers
        }
        if let newCatalogue, let document = try? SignedDocument(serializedBytes: newCatalogue), let members = next.signedMembers,
           (try? Sealing.verifiedCatalogue(document, members: members, current: signedCatalogue)) != nil {
            next.catalogue = newCatalogue
        }
        if let newURL, !newURL.isEmpty { next.answerURL = newURL }
        return next
    }
}

public struct WatchStore: Sendable {
    let accessGroup: String?
    static let account = "saved.v2"

    public init(accessGroup: String?) { self.accessGroup = accessGroup }
    public init() { self.init(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String) }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: WatchKeys.service,
                                    kSecAttrAccount as String: Self.account, kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read() -> WatchSaved {
        var copy = query
        copy[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(copy as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let saved = try? PropertyListDecoder().decode(WatchSaved.self, from: data) else { return WatchSaved() }
        return saved
    }

    public func write(_ saved: WatchSaved) {
        guard let data = try? PropertyListEncoder().encode(saved) else { return }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
