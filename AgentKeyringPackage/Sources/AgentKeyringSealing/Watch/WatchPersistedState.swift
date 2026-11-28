// Written by AI on 2026.11.18 by model claude opus 5.5;
// protobuf persistence on 2026.11.27.
//
// What the iPhone hands the Watch, kept in one keychain item the app shares
// with its notification service extension: the signed Members (who may ask),
// the signed Catalogue (the logins' names and sites), the iPhone's settings,
// and the end of a Face ID confirmation the iPhone holds for it to be added;
// and the few things the Watch keeps of its own setup.

import AgentKeyringProtocol
import Foundation
#if os(watchOS)
import Security
#endif

public struct WatchPersistedState: Sendable, Equatable {
    public static let protobufMagic = Data("AKRWCH02".utf8)

    public var members: Data?
    public var catalogue: Data?
    /// The iPhone's notification settings, which Apple Watch follows.
    public var settings: NotificationSettings?
    /// He has answered a practice request on this Apple Watch.
    public var practiceAnswered: Bool?
    /// The iPhone waits for this Watch to ask until then: Add is offered only before it.
    public var addUntil: Date?
    /// The specific Face ID Add offer ID sent by the iPhone, echoed back on Add.
    public var addOfferID: String?
    /// The specific Face ID Add offer ID that he tapped Add for on this Watch.
    var addTappedOfferID: String?
    /// True while the Watch is listed in Members but the Mac has not yet acknowledged its encrypted copies.
    public var copiesPending: Bool?
    /// True while the iPhone is actively encrypting/uploading Watch copies.
    public var copyingToWatch: Bool?
    /// When Try Practice asked for a practice request.
    public var practiceAsked: Date?
    /// Done on the practice offer, or a practice answered.
    public var practiceOfferDone: Bool?
    /// Timestamp of the latest iPhone reset applied on this Watch, so a fresh keyring starting at revision 1
    /// cleanly replaces any older keyring chain.
    public var lastResetAt: Double?
    /// Timestamp (`sentAt`) of the newest iPhone control payload applied, so guaranteed `transferUserInfo`
    /// deliveries can update Add offer / copying state without older queued deliveries overwriting newer ones.
    public var lastContextSentAt: Double?
    /// The iPhone's relay when it is not the default: Apple Watch answers in boxes there too.
    public var relayURL: String?

    public init(members: Data? = nil, catalogue: Data? = nil) {
        self.members = members; self.catalogue = catalogue
    }

    public func encodeProtobuf() throws -> Data {
        Self.protobufMagic + (try storedProto().serializedData())
    }

    public static func decodeProtobuf(_ data: Data) -> WatchPersistedState? {
        guard data.starts(with: protobufMagic) else { return nil }
        guard let proto = try? Agentkeyring_V2_StoredWatchState(
            serializedBytes: Data(data.dropFirst(protobufMagic.count))
        ) else {
            return nil
        }
        return WatchPersistedState(storedProto: proto)
    }

    init(storedProto proto: Agentkeyring_V2_StoredWatchState) {
        members = proto.hasMembers ? proto.members : nil
        catalogue = proto.hasCatalogue ? proto.catalogue : nil
        if proto.hasSettings {
            var decoded = NotificationSettings()
            decoded.timeSensitive = proto.settings.timeSensitive
            decoded.quietHours = proto.settings.quietHours
            decoded.quietFrom = Int(proto.settings.quietFromMinutes)
            decoded.quietTo = Int(proto.settings.quietToMinutes)
            settings = decoded
        } else {
            settings = nil
        }
        practiceAnswered = proto.hasPracticeAnswered ? proto.practiceAnswered : nil
        addUntil = proto.hasAddUntilUnixSeconds ? Date(timeIntervalSince1970: proto.addUntilUnixSeconds) : nil
        addOfferID = proto.hasAddOfferID ? proto.addOfferID : nil
        addTappedOfferID = proto.hasAddTappedOfferID ? proto.addTappedOfferID : nil
        copiesPending = proto.hasCopiesPending ? proto.copiesPending : nil
        copyingToWatch = proto.hasCopyingToWatch ? proto.copyingToWatch : nil
        practiceAsked = proto.hasPracticeAskedUnixSeconds ? Date(timeIntervalSince1970: proto.practiceAskedUnixSeconds) : nil
        practiceOfferDone = proto.hasPracticeOfferDone ? proto.practiceOfferDone : nil
        lastResetAt = proto.hasLastResetAtUnixSeconds ? proto.lastResetAtUnixSeconds : nil
        lastContextSentAt = proto.hasLastContextSentAtUnixSeconds ? proto.lastContextSentAtUnixSeconds : nil
        relayURL = proto.hasRelayURL ? proto.relayURL : nil
    }

    func storedProto() -> Agentkeyring_V2_StoredWatchState {
        var proto = Agentkeyring_V2_StoredWatchState()
        if let members { proto.members = members }
        if let catalogue { proto.catalogue = catalogue }
        if let settings {
            var stored = Agentkeyring_V2_WatchNotificationSettings()
            stored.timeSensitive = settings.timeSensitive
            stored.quietHours = settings.quietHours
            stored.quietFromMinutes = Int32(settings.quietFrom)
            stored.quietToMinutes = Int32(settings.quietTo)
            proto.settings = stored
        }
        if let practiceAnswered { proto.practiceAnswered = practiceAnswered }
        if let addUntil { proto.addUntilUnixSeconds = addUntil.timeIntervalSince1970 }
        if let addOfferID { proto.addOfferID = addOfferID }
        if let addTappedOfferID { proto.addTappedOfferID = addTappedOfferID }
        if let copiesPending { proto.copiesPending = copiesPending }
        if let copyingToWatch { proto.copyingToWatch = copyingToWatch }
        if let practiceAsked { proto.practiceAskedUnixSeconds = practiceAsked.timeIntervalSince1970 }
        if let practiceOfferDone { proto.practiceOfferDone = practiceOfferDone }
        if let lastResetAt { proto.lastResetAtUnixSeconds = lastResetAt }
        if let lastContextSentAt { proto.lastContextSentAtUnixSeconds = lastContextSentAt }
        if let relayURL { proto.relayURL = relayURL }
        return proto
    }

    /// Offer ID for the current Face ID confirmation.
    var effectiveAddOfferID: String? {
        guard let addOfferID, !addOfferID.isEmpty else { return nil }
        return addOfferID
    }

    /// True only when he tapped Add for the current Face ID offer (or while the iPhone is actively copying for it).
    var isAddTappedForCurrentOffer: Bool {
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

    /// Whether a request arriving now may break through a Focus.
    public var breaksThroughFocus: Bool { (settings ?? NotificationSettings()).breaksThroughFocus() }

    /// The Watch is set up once a Members the iPhone signed lists it.
    public func lists(_ keyID: String) -> Bool { signedMembers?.devices.contains { $0.keyID == keyID } ?? false }

    /// Takes what the iPhone sent. A newer Members must be signed by a device in
    /// the list Apple Watch already trusts (the first one by a device it names
    /// itself). It need not follow every revision in between: it may have missed
    /// some while asleep, and the iPhone and Mac that sign them stay in the list.
    public func merging(members newMembers: Data?, catalogue newCatalogue: Data?, settings newSettings: NotificationSettings? = nil,
                        addUntil: Date?, addOfferID: String? = nil,
                        copiesPending: Bool? = nil, copyingToWatch: Bool? = nil) -> WatchPersistedState {
        var merged = self
        merged.addUntil = addUntil
        merged.addOfferID = addOfferID
        if let copiesPending { merged.copiesPending = copiesPending }
        if let copyingToWatch { merged.copyingToWatch = copyingToWatch }
        if let newSettings { merged.settings = newSettings }
        if let newMembers, let document = try? SignedDocument(serializedBytes: newMembers),
           // Chained from the list Apple Watch already trusts: a newer list must be signed by a device in it.
           let next = try? CredentialSealing.verifySignedMembers(document, current: signedMembers),
           next.revision > (signedMembers?.revision ?? 0) {
            merged.members = newMembers
        }
        if let newCatalogue, let document = try? SignedDocument(serializedBytes: newCatalogue), let members = merged.signedMembers,
           (try? CredentialSealing.verifySignedCatalogue(document, members: members, current: signedCatalogue)) != nil {
            merged.catalogue = newCatalogue
        }
        return merged
    }
}

/// The relay Apple Watch answers at besides the default: one set at launch (`-AgentKeyringRelayURL`), else the
/// iPhone's, so requests from computers enrolled on a self-hosted relay can be answered here.
public enum WatchRelayConfiguration {
    /// Read by the app at launch, before anything checks a request.
    nonisolated(unsafe) public static var launchSetting: String?

    public static func applyRelayOverride(_ saved: WatchPersistedState) {
        RelayBoxClient.overrideURL = launchSetting ?? saved.relayURL
    }
}

/// One approval that still lasts (Paper, "On iPhone and Apple Watch", Apple Watch, "In use").
public struct WatchInUse: Sendable, Equatable, Identifiable {
    public static let protobufMagic = Data("AKRWIU02".utf8)

    public let id: String
    public let site: String
    /// "Claude Code on MacBook Pro".
    public let who: String
    public let until: Date
    /// True when this request already ended/stopped so a delayed approval push cannot resurrect it.
    public let ended: Bool?

    public init(id: String, site: String, who: String, until: Date, ended: Bool? = nil) {
        self.id = id; self.site = site; self.who = who; self.until = until; self.ended = ended
    }

    public func encodeProtobuf() throws -> Data {
        var proto = Agentkeyring_V2_StoredWatchInUse()
        proto.id = id
        proto.site = site
        proto.who = who
        proto.untilUnixSeconds = until.timeIntervalSince1970
        proto.ended = ended == true
        return Self.protobufMagic + (try proto.serializedData())
    }

    public static func decodeProtobuf(_ data: Data) -> WatchInUse? {
        guard data.starts(with: protobufMagic) else { return nil }
        guard let proto = try? Agentkeyring_V2_StoredWatchInUse(
            serializedBytes: Data(data.dropFirst(protobufMagic.count))
        ) else {
            return nil
        }
        return WatchInUse(
            id: proto.id,
            site: proto.site,
            who: proto.who,
            until: Date(timeIntervalSince1970: proto.untilUnixSeconds),
            ended: proto.ended ? true : nil
        )
    }
}

#if os(watchOS)
public struct WatchKeychainStateStore: Sendable {
    private static let lock = NSLock()
    let accessGroup: String?
    /// v3 is the direct protocol: a Watch updated from a relay-era build starts with nothing, never with a
    /// list of devices signed by an iPhone and Mac that no longer exist, which no new list could follow.
    static let account = "saved.v3"
    /// Stored separately so frequent WatchPersistedState flag updates never rewrite a large signed Catalogue.
    static let catalogueAccount = "catalogue.v3"
    /// Dedicated keychain service where each active approval ("In use") is stored as its own item
    /// keyed by approval ID, so the Watch app and Notification Service Extension never race on one array.
    static let inUseService = WatchKeys.service + ".in-use.v3"

    public init(accessGroup: String?) { self.accessGroup = accessGroup }
    public init() { self.init(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String) }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: WatchKeys.service,
                                    kSecAttrAccount as String: Self.account, kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private var catalogueQuery: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: WatchKeys.service,
                                    kSecAttrAccount as String: Self.catalogueAccount, kSecUseDataProtectionKeychain as String: true]
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

    public func readWatchState() -> WatchPersistedState {
        Self.lock.withLock { (try? readUnlocked()) ?? WatchPersistedState() }
    }

    /// Reads all active "In use" items across per-approval keychain records and prunes expired ones individually.
    /// Enumerates attributes first (Apple does not support `kSecMatchLimitAll` combined with `kSecReturnData`
    /// on generic-password items), then fetches each item individually.
    public func readInUse() -> [WatchInUse] {
        Self.lock.withLock {
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
            var live: [WatchInUse] = []
            for record in records {
                guard let id = record[kSecAttrAccount as String] as? String, !id.isEmpty else { continue }
                guard let item = readInUseItemUnlocked(id: id) else { continue }
                if item.until > now {
                    if item.ended != true { live.append(item) }
                } else {
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
        return WatchInUse.decodeProtobuf(data)
    }

    /// Records a single request outcome in its own keychain item without writing `saved.v3` or other approvals.
    /// Keeps a short-lived tombstone on ended outcomes so a delayed approval push can never resurrect a stopped item.
    public func noteOutcome(_ request: WatchRequest) {
        Self.lock.withLock {
            if let until = request.inUseUntil, until > .now {
                if let existing = readInUseItemUnlocked(id: request.id), existing.ended == true, existing.until > .now {
                    return
                }
                writeInUseItemUnlocked(WatchInUse(id: request.id, site: request.site, who: request.who, until: until))
            } else {
                writeEndedTombstoneUnlocked(id: request.id)
            }
        }
    }

    func addInUse(_ item: WatchInUse) {
        Self.lock.withLock {
            if item.until > .now {
                if let existing = readInUseItemUnlocked(id: item.id), existing.ended == true, existing.until > .now {
                    return
                }
                writeInUseItemUnlocked(item)
            } else {
                writeEndedTombstoneUnlocked(id: item.id)
            }
        }
    }

    public func removeInUse(_ id: String) {
        Self.lock.withLock {
            writeEndedTombstoneUnlocked(id: id)
        }
    }

    private func writeEndedTombstoneUnlocked(id: String) {
        writeInUseItemUnlocked(WatchInUse(id: id, site: "", who: "", until: Date().addingTimeInterval(3600), ended: true))
    }

    private func removeInUseItemUnlocked(id: String) {
        _ = SecItemDelete(inUseItemQuery(id: id) as CFDictionary)
    }

    func clearInUse() {
        Self.lock.withLock {
            _ = SecItemDelete(allInUseQuery as CFDictionary)
        }
    }

    private func writeInUseItemUnlocked(_ item: WatchInUse) {
        guard let data = try? item.encodeProtobuf() else { return }
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

    /// Atomically reads, transforms, and persists WatchPersistedState within this process so concurrent
    /// WatchConnectivity and notification callbacks cannot overwrite each other's updates.
    @discardableResult
    public func update(_ transform: (inout WatchPersistedState) -> Void) -> WatchPersistedState {
        updateIfReadable(transform) ?? WatchPersistedState()
    }

    func updateIfReadable(_ transform: (inout WatchPersistedState) -> Void) -> WatchPersistedState? {
        Self.lock.withLock {
            guard let before = try? readUnlocked() else { return nil }
            var current = before
            transform(&current)
            if current != before, !writeUnlocked(current, previousCatalogue: before.catalogue) {
                return nil
            }
            return current
        }
    }

    private func readUnlocked() throws -> WatchPersistedState {
        guard let data = try readItemUnlocked(query) else { return WatchPersistedState() }
        guard var saved = WatchPersistedState.decodeProtobuf(data) else {
            // A state this build cannot decode starts again; only a keychain that cannot be read holds writes.
            KeyringDiagnosticLog.watch.noteDeviceEvent("state", "undecodable, starting again")
            _ = SecItemDelete(query as CFDictionary)
            _ = SecItemDelete(catalogueQuery as CFDictionary)
            return WatchPersistedState()
        }
        if let catalogue = try readItemUnlocked(catalogueQuery) { saved.catalogue = catalogue }
        return saved
    }

    private func readItemUnlocked(_ item: [String: Any]) throws -> Data? {
        var readQuery = item
        readQuery[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode)) }
        return data
    }

    /// Forgets what the iPhone handed over. A new install starts here: the
    /// keychain keeps this item when the app is removed, and an earlier install's
    /// list of devices would never let the new one in.
    public func deleteWatchState() {
        Self.lock.withLock {
            _ = SecItemDelete(query as CFDictionary)
            _ = SecItemDelete(catalogueQuery as CFDictionary)
            _ = SecItemDelete(allInUseQuery as CFDictionary)
        }
    }

    func writeWatchState(_ saved: WatchPersistedState) {
        Self.lock.withLock { _ = writeUnlocked(saved, previousCatalogue: nil) }
    }

    private func writeUnlocked(_ saved: WatchPersistedState, previousCatalogue: Data?) -> Bool {
        var lean = saved
        lean.catalogue = nil
        guard let data = try? lean.encodeProtobuf() else { return false }
        if saved.catalogue != previousCatalogue || previousCatalogue == nil {
            if let catalogue = saved.catalogue {
                guard writeItemUnlocked(catalogue, to: catalogueQuery) else { return false }
            } else {
                let status = SecItemDelete(catalogueQuery as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { return false }
            }
        }
        return writeItemUnlocked(data, to: query)
    }

    private func writeItemUnlocked(_ data: Data, to item: [String: Any]) -> Bool {
        let updated = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
#endif
