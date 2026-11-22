// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// What the iPhone hands the Watch, kept in one keychain item the app shares
// with its notification service extension: the signed Members (who may ask),
// the signed Catalogue (the logins' names and sites), the iPhone's settings,
// and the end of a Face ID confirmation the iPhone holds for it to be added;
// and the few things the Watch keeps of its own setup.

#if os(watchOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Security

public struct WatchSaved: Codable, Sendable, Equatable {
    public var members: Data?
    public var catalogue: Data?
    /// The iPhone's notification settings, which Apple Watch follows.
    public var settings: NotificationSettings?
    /// Approvals that still last, from the outcome pushes every device receives.
    public var inUse: [WatchInUse]?
    /// He has answered a practice request on this Apple Watch.
    public var practiceAnswered: Bool?
    /// The iPhone waits for this Watch to ask until then: Add is offered only before it.
    public var addUntil: Date?
    /// The specific Face ID Add offer ID sent by the iPhone, echoed back on Add.
    public var addOfferID: String?
    /// The specific Face ID Add offer ID that he tapped Add for on this Watch.
    public var addTappedOfferID: String?
    /// True while the Watch is listed in Members but the Mac has not yet acknowledged its encrypted copies.
    public var copiesPending: Bool?
    /// True while the iPhone is actively encrypting/uploading Watch copies.
    public var copyingToWatch: Bool?
    /// When Try Practice asked for a practice request.
    public var practiceAsked: Date?
    /// Done on the practice offer, or a practice answered.
    public var practiceOfferDone: Bool?

    public init(members: Data? = nil, catalogue: Data? = nil) {
        self.members = members; self.catalogue = catalogue
    }

    /// Effective offer ID for the current Face ID confirmation (falls back to `addUntil` for older iPhone builds).
    public var effectiveAddOfferID: String? {
        if let addOfferID, !addOfferID.isEmpty { return addOfferID }
        guard let addUntil, addUntil > .now else { return nil }
        return "legacy-\(Int(addUntil.timeIntervalSince1970))"
    }

    /// True only when he tapped Add for the current Face ID offer (or while the iPhone is actively copying for it).
    public var isAddTappedForCurrentOffer: Bool {
        guard let tapped = addTappedOfferID, !tapped.isEmpty else { return false }
        if copyingToWatch == true { return true }
        guard let current = effectiveAddOfferID else { return false }
        return tapped == current
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
    public func merging(members newMembers: Data?, catalogue newCatalogue: Data?, settings newSettings: Data? = nil,
                        addUntil: Date?, addOfferID: String? = nil,
                        copiesPending: Bool? = nil, copyingToWatch: Bool? = nil) -> WatchSaved {
        var merged = self
        merged.addUntil = addUntil
        merged.addOfferID = addOfferID
        if let copiesPending { merged.copiesPending = copiesPending }
        if let copyingToWatch { merged.copyingToWatch = copyingToWatch }
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
    private static let lock = NSLock()
    let accessGroup: String?
    /// v3 is the direct protocol: a Watch updated from a relay-era build starts with nothing, never with a
    /// list of devices signed by an iPhone and Mac that no longer exist, which no new list could follow.
    static let account = "saved.v3"
    /// Legacy combined key deleted on clear/reset.
    static let legacyInUseAccount = "in-use.v3"
    /// Dedicated keychain service where each active approval ("In use") is stored as its own item
    /// keyed by approval ID, so the Watch app and Notification Service Extension never race on one array.
    static let inUseService = WatchKeys.service + ".in-use.v3"

    public init(accessGroup: String?) { self.accessGroup = accessGroup }
    public init() { self.init(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String) }

    private var query: [String: Any] { query(account: Self.account) }
    private var legacyInUseQuery: [String: Any] { query(account: Self.legacyInUseAccount) }

    private func query(account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: WatchKeys.service,
                                    kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func inUseItemQuery(id: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.inUseService,
                                    kSecAttrAccount as String: id, kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private var allInUseQuery: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.inUseService,
                                    kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read() -> WatchSaved {
        Self.lock.withLock { readUnlocked() }
    }

    /// Reads all active "In use" items across per-approval keychain records and prunes expired ones individually.
    /// Enumerates attributes first (Apple does not support `kSecMatchLimitAll` combined with `kSecReturnData`
    /// on generic-password items), fetches each item individually, and migrates any unexpired legacy records.
    public func readInUse() -> [WatchInUse] {
        Self.lock.withLock {
            migrateLegacyInUseUnlocked()
            var listQuery = allInUseQuery
            listQuery[kSecReturnAttributes as String] = true
            listQuery[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            let status = SecItemCopyMatching(listQuery as CFDictionary, &result)
            guard status == errSecSuccess else { return [] }
            let records: [[String: Any]]
            if let many = result as? [[String: Any]] {
                records = many
            } else if let one = result as? [String: Any] {
                records = [one]
            } else {
                return []
            }
            let now = Date()
            let canPruneExpired = !hasUnretiredLegacyInUseUnlocked()
            var live: [WatchInUse] = []
            for record in records {
                guard let id = record[kSecAttrAccount as String] as? String, !id.isEmpty else { continue }
                guard let item = readInUseItemUnlocked(id: id) else { continue }
                if item.until > now {
                    live.append(item)
                } else if canPruneExpired {
                    _ = SecItemDelete(inUseItemQuery(id: id) as CFDictionary)
                }
            }
            return live.sorted { $0.until > $1.until }
        }
    }

    private func readInUseItemUnlocked(id: String) -> WatchInUse? {
        var query = inUseItemQuery(id: id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? PropertyListDecoder().decode(WatchInUse.self, from: data)
    }

    /// Migrates any unexpired active approvals stored in the legacy single-array `in-use.v3` keychain item
    /// using conditional insert (`SecItemAdd` only) so a concurrent Stop tombstone can never be overwritten.
    /// Deletes the legacy record only after every unexpired item succeeded or already had a per-item record.
    private func migrateLegacyInUseArrayUnlocked() {
        let now = Date()
        var legacyQuery = legacyInUseQuery
        legacyQuery[kSecReturnData as String] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let legacy = try? PropertyListDecoder().decode([WatchInUse].self, from: data) {
            var allMigrated = true
            for item in legacy where item.until > now {
                if !addInUseItemIfAbsentUnlocked(item) { allMigrated = false }
            }
            if allMigrated {
                _ = SecItemDelete(legacyInUseQuery as CFDictionary)
            }
        }
    }

    /// Migrates both legacy `in-use.v3` and pre-v3 `saved.v3.inUse` arrays on Watch app reads
    /// using conditional insert (`SecItemAdd` only), so overlapping Stop tombstones always win.
    private func migrateLegacyInUseUnlocked() {
        migrateLegacyInUseArrayUnlocked()
        let now = Date()
        let saved = readUnlocked()
        if let legacySaved = saved.inUse, !legacySaved.isEmpty {
            var allMigrated = true
            for item in legacySaved where item.until > now {
                if !addInUseItemIfAbsentUnlocked(item) { allMigrated = false }
            }
            if allMigrated {
                var cleaned = saved
                cleaned.inUse = nil
                writeUnlocked(cleaned)
            }
        }
    }

    /// Returns true unless both legacy sources (`in-use.v3` and `saved.v3.inUse`) are confirmed absent or empty.
    /// Any transient Keychain read failure fails closed so stop tombstones are never pruned prematurely.
    private func hasUnretiredLegacyInUseUnlocked() -> Bool {
        var legacyProbe = legacyInUseQuery
        legacyProbe[kSecReturnAttributes as String] = true
        var legacyResult: CFTypeRef?
        let legacyStatus = SecItemCopyMatching(legacyProbe as CFDictionary, &legacyResult)
        if legacyStatus != errSecItemNotFound { return true }

        var savedQuery = query
        savedQuery[kSecReturnData as String] = true
        var savedResult: CFTypeRef?
        let savedStatus = SecItemCopyMatching(savedQuery as CFDictionary, &savedResult)
        if savedStatus == errSecItemNotFound { return false }
        guard savedStatus == errSecSuccess,
              let data = savedResult as? Data,
              let saved = try? PropertyListDecoder().decode(WatchSaved.self, from: data) else { return true }
        return !(saved.inUse ?? []).isEmpty
    }

    /// Records a single request outcome in its own keychain item without writing `saved.v3` or other approvals.
    public func noteOutcome(_ request: WatchRequest) {
        Self.lock.withLock {
            if let until = request.inUseUntil, until > .now {
                writeInUseItemUnlocked(WatchInUse(id: request.id, site: request.site, who: request.who, until: until))
            } else {
                removeOrTombstoneInUseUnlocked(id: request.id)
            }
        }
    }

    public func addInUse(_ item: WatchInUse) {
        Self.lock.withLock {
            if item.until > .now {
                writeInUseItemUnlocked(item)
            } else {
                removeOrTombstoneInUseUnlocked(id: item.id)
            }
        }
    }

    public func removeInUse(_ id: String) {
        Self.lock.withLock {
            removeOrTombstoneInUseUnlocked(id: id)
        }
    }

    /// Writes an expired tombstone while either legacy source (`in-use.v3` or `saved.v3.inUse`) is still
    /// unretired so an overlapping migration's conditional `SecItemAdd` cannot resurrect a stopped approval.
    /// Once both legacy sources are retired, deletes the item directly.
    private func removeOrTombstoneInUseUnlocked(id: String) {
        if hasUnretiredLegacyInUseUnlocked() {
            writeInUseItemUnlocked(WatchInUse(id: id, site: "", who: "", until: .distantPast))
        } else {
            _ = SecItemDelete(inUseItemQuery(id: id) as CFDictionary)
        }
    }

    /// Atomically inserts a migrated item only if no record (live or tombstone) already exists for `item.id`.
    /// Returns true when the item was inserted or a per-item record already exists.
    private func addInUseItemIfAbsentUnlocked(_ item: WatchInUse) -> Bool {
        guard let data = try? PropertyListEncoder().encode(item) else { return false }
        var add = inUseItemQuery(id: item.id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    public func clearInUse() {
        Self.lock.withLock {
            _ = SecItemDelete(allInUseQuery as CFDictionary)
            _ = SecItemDelete(legacyInUseQuery as CFDictionary)
        }
    }

    private func writeInUseItemUnlocked(_ item: WatchInUse) {
        guard let data = try? PropertyListEncoder().encode(item) else { return }
        let itemQuery = inUseItemQuery(id: item.id)
        let updated = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return }
        var add = itemQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem {
            // Another process inserted a record between our update and add; overwrite it with our newer state.
            _ = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    /// Atomically reads, transforms, and persists WatchSaved within this process so concurrent
    /// WatchConnectivity and notification callbacks cannot overwrite each other's updates.
    @discardableResult
    public func update(_ transform: (inout WatchSaved) -> Void) -> WatchSaved {
        Self.lock.withLock {
            var current = readUnlocked()
            let before = current
            transform(&current)
            if current != before { writeUnlocked(current) }
            return current
        }
    }

    private func readUnlocked() -> WatchSaved {
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
    public func delete() {
        Self.lock.withLock {
            _ = SecItemDelete(query as CFDictionary)
            _ = SecItemDelete(allInUseQuery as CFDictionary)
            _ = SecItemDelete(legacyInUseQuery as CFDictionary)
        }
    }

    public func write(_ saved: WatchSaved) {
        Self.lock.withLock { writeUnlocked(saved) }
    }

    private func writeUnlocked(_ saved: WatchSaved) {
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
