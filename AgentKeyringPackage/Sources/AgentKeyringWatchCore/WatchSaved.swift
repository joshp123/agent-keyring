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
    /// The iPhone's notification settings, which Apple Watch follows.
    public var settings: NotificationSettings?
    /// Approvals that still last, from the outcome pushes every device receives.
    public var inUse: [WatchInUse]?

    public init(members: Data? = nil, catalogue: Data? = nil, answerURL: String? = nil) {
        self.members = members; self.catalogue = catalogue; self.answerURL = answerURL
    }

    public var signedMembers: Members? {
        members.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Members(serializedBytes: $0.payload) }
    }

    public var signedCatalogue: Catalogue? {
        catalogue.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Catalogue(serializedBytes: $0.payload) }
    }

    /// What is in use now, soonest ending last.
    public var currentInUse: [WatchInUse] { (inUse ?? []).filter { $0.until > .now }.sorted { $0.until > $1.until } }

    /// Notes a request's state: an approval that lasts is in use; any other end removes it.
    public func noting(_ request: WatchRequest) -> WatchSaved {
        var next = self
        var list = currentInUse.filter { $0.id != request.id }
        if let until = request.inUseUntil { list.append(WatchInUse(id: request.id, site: request.site, who: request.who, until: until)) }
        next.inUse = list
        return next
    }

    public func addingInUse(_ item: WatchInUse) -> WatchSaved {
        var next = self
        next.inUse = currentInUse.filter { $0.id != item.id } + [item]
        return next
    }

    public func removingInUse(_ id: String) -> WatchSaved {
        var next = self
        next.inUse = currentInUse.filter { $0.id != id }
        return next
    }

    /// Whether a request arriving now may break through a Focus.
    public var breaksThroughFocus: Bool { (settings ?? NotificationSettings()).breaksThroughFocus() }

    /// The Watch is set up once a Members the iPhone signed lists it.
    public func lists(_ keyID: String) -> Bool { signedMembers?.devices.contains { $0.keyID == keyID } ?? false }

    /// Takes what the iPhone sent. A newer Members must be signed by a device in
    /// the list Apple Watch already trusts (the first one by a device it names
    /// itself). It need not follow every revision in between: it may have missed
    /// some while asleep, and the iPhone and Mac that sign them stay in the list.
    public func merging(members newMembers: Data?, catalogue newCatalogue: Data?, answerURL newURL: String?, settings newSettings: Data? = nil) -> WatchSaved {
        var merged = self
        if let newSettings, let settings = try? PropertyListDecoder().decode(NotificationSettings.self, from: newSettings) { merged.settings = settings }
        if let newMembers, let document = try? SignedDocument(serializedBytes: newMembers),
           // Chained from the list Apple Watch already trusts: a newer list must be signed by a device in it.
           let next = try? Sealing.verifiedMembers(document, current: signedMembers),
           next.revision > (signedMembers?.revision ?? 0) {
            merged.members = newMembers
        }
        if let newCatalogue, let document = try? SignedDocument(serializedBytes: newCatalogue), let members = merged.signedMembers,
           (try? Sealing.verifiedCatalogue(document, members: members, current: signedCatalogue)) != nil {
            merged.catalogue = newCatalogue
        }
        if let newURL, !newURL.isEmpty { merged.answerURL = newURL }
        return merged
    }
}

/// One approval that still lasts (Paper, "On iPhone and Apple Watch", Apple Watch, "In use").
public struct WatchInUse: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let site: String
    /// "Claude Code on MacBook Pro".
    public let who: String
    public let until: Date

    public init(id: String, site: String, who: String, until: Date) { self.id = id; self.site = site; self.who = who; self.until = until }
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

    /// Forgets what the iPhone handed over. A new install starts here: the
    /// keychain keeps this item when the app is removed, and an earlier install's
    /// list of devices would never let the new one in.
    public func delete() { SecItemDelete(query as CFDictionary) }

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
