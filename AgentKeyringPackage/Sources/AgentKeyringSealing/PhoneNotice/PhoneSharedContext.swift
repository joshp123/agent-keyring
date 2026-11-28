// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// What the iPhone app shares with its notification service extension through
// the shared keychain group. Kept in a slim target so the extension never
// pulls in iCloud, credential import or the domain catalogue.

import AgentKeyringProtocol
import Foundation
import Security

/// The subset of `PhoneSavedState` that the notification service extension reads.
public struct PhoneSharedSnapshot: Sendable {
    public var deviceKeyID: String?
    public var members: Data?
    public var catalogue: Data?
    public var settings: NotificationSettings?

    public init(deviceKeyID: String? = nil, members: Data? = nil, catalogue: Data? = nil, settings: NotificationSettings? = nil) {
        self.deviceKeyID = deviceKeyID
        self.members = members
        self.catalogue = catalogue
        self.settings = settings
    }
}

/// What the notification service extension needs to name a request: this iPhone's key id, the Members
/// and the Catalogue. Kept in the keychain group the app shares with the extension, readable once the
/// phone has been unlocked after starting up.
public struct PhoneSharedContext: Sendable {
    private static let magicV2 = Data("AKRCTX02".utf8)
    let service = "com.joshpalmer.AgentKeyring.Phone.shared-context"
    let accessGroup: String?
    /// Set only by `memory()`: the context then lives in this process and never touches the keychain.
    private let inMemoryStore: PhoneSharedContextMemoryStore?

    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
        self.inMemoryStore = nil
    }

    private init(inMemoryStore: PhoneSharedContextMemoryStore) {
        self.accessGroup = nil
        self.inMemoryStore = inMemoryStore
    }

    /// A context held only in memory, for test peers that must never write the real keychain.
    package static func memory() -> PhoneSharedContext {
        PhoneSharedContext(inMemoryStore: PhoneSharedContextMemoryStore())
    }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "context", kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func writeData(_ data: Data) {
        if let inMemoryStore { return inMemoryStore.set(data) }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Forgets what the extension was handed: the keychain keeps it when the app is removed.
    public func deleteSharedContext() {
        if let inMemoryStore { return inMemoryStore.set(nil) }
        SecItemDelete(query as CFDictionary)
    }

    func readData() -> Data? {
        if let inMemoryStore { return inMemoryStore.get() }
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    public func writeSnapshot(_ snapshot: PhoneSharedSnapshot) {
        guard let data = try? Self.encodeSnapshot(snapshot) else { return }
        writeData(data)
    }

    func readSnapshot() -> PhoneSharedSnapshot? {
        guard let data = readData() else { return nil }
        return Self.decodeSnapshot(data)
    }

    public static func encodeSnapshot(_ snapshot: PhoneSharedSnapshot) throws -> Data {
        var proto = Agentkeyring_V2_StoredPhoneSharedContext()
        if let deviceKeyID = snapshot.deviceKeyID { proto.deviceKeyID = deviceKeyID }
        if let members = snapshot.members { proto.members = members }
        if let catalogue = snapshot.catalogue { proto.catalogue = catalogue }
        if let settings = snapshot.settings {
            var protoSettings = Agentkeyring_V2_WatchNotificationSettings()
            protoSettings.timeSensitive = settings.timeSensitive
            protoSettings.quietHours = settings.quietHours
            protoSettings.quietFromMinutes = Int32(settings.quietFrom)
            protoSettings.quietToMinutes = Int32(settings.quietTo)
            proto.settings = protoSettings
            proto.hasSettings_p = true
        }
        return magicV2 + (try proto.serializedData())
    }

    public static func decodeSnapshot(_ data: Data) -> PhoneSharedSnapshot? {
        guard data.starts(with: magicV2) else { return nil }
        guard let proto = try? Agentkeyring_V2_StoredPhoneSharedContext(
            serializedBytes: Data(data.dropFirst(magicV2.count))
        ) else {
            return nil
        }
        var settings: NotificationSettings?
        if proto.hasSettings_p || proto.hasSettings {
            var decoded = NotificationSettings()
            decoded.timeSensitive = proto.settings.timeSensitive
            decoded.quietHours = proto.settings.quietHours
            decoded.quietFrom = Int(proto.settings.quietFromMinutes)
            decoded.quietTo = Int(proto.settings.quietToMinutes)
            settings = decoded
        }
        return PhoneSharedSnapshot(
            deviceKeyID: proto.hasDeviceKeyID ? proto.deviceKeyID : nil,
            members: proto.hasMembers ? proto.members : nil,
            catalogue: proto.hasCatalogue ? proto.catalogue : nil,
            settings: settings
        )
    }
}

/// The bytes a `PhoneSharedContext.memory()` context holds, shared by every copy of that context.
final class PhoneSharedContextMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func get() -> Data? { lock.withLock { data } }
    func set(_ next: Data?) { lock.withLock { data = next } }
}
