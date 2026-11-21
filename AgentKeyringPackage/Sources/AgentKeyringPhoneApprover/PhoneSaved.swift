// Written by AI on 2026.11.18 by model Claude Opus 5.5; for the direct protocol on 2026.11.21.
//
// What the iPhone keeps between launches, and what it shares with its
// notification service extension.

import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Security
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

typealias Work = Agentkeyring_V2_Work
typealias Lease = Agentkeyring_V2_Lease

/// The Mac this iPhone joined: its door, a Tailscale IP and port, pinned to its key.
struct MacDoor: Codable, Equatable {
    var host: String
    var port: UInt16
    var key: Data
    var name: String
}

struct PhoneSavedState: Codable {
    var mac: MacDoor?
    var members: Data?
    var catalogue: Data?
    /// This iPhone's own copy of every password that is not Blocked, as the Mac sent them: serialized SealedLogins.
    var copies: Data?
    /// request id → serialized Work, the latest this iPhone has seen of it.
    var work: [String: Data] = [:]
    /// request id → what this iPhone answered, until the outcome arrives.
    var answered: [String: Bool] = [:]
    /// This iPhone's Device.key_id, once joined; the extension needs it to open a notice.
    var deviceKeyID: String?
    /// Where first run stands; a step an earlier build saved that this build no longer has reads as nil,
    /// never as a broken state.
    @Lenient var firstRun: PhoneFirstRun?
    /// A push reached this iPhone since it joined.
    var pushSeen = false
    /// What the Watch found when it tested itself, as its app sent it (a property list).
    var watchSelfTest: Data?
    /// The Watch's Device and PushRegistration, serialized, as its app sent them after Add, until it is listed.
    var watchDevice: Data?
    var watchPush: Data?
    /// The notification settings; nil means the defaults.
    var settings: NotificationSettings?
    /// SHA-256 of the push address registered with the Mac: a locked iPhone's arrival note names it.
    var pushTokenSHA256: Data?
}

/// A saved value that reads as nil when its form has changed, so the rest of the saved state still reads.
@propertyWrapper
struct Lenient<Value: Codable>: Codable {
    var wrappedValue: Value?
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try? Value(from: decoder) }
    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}

extension KeyedDecodingContainer {
    func decode<Value>(_ type: Lenient<Value>.Type, forKey key: Key) throws -> Lenient<Value> {
        try decodeIfPresent(type, forKey: key) ?? Lenient(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    mutating func encode<Value>(_ value: Lenient<Value>, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}

/// What the notification service extension needs to name a request: this iPhone's key id, the Members
/// and the Catalogue; and to tell the asking computer it arrived: the push address's hash. Kept in the
/// keychain group the app shares with the extension, readable once the phone has been unlocked after
/// starting up.
public struct PhoneSharedContext {
    let service = "com.joshpalmer.AgentKeyring.Phone.shared-context"
    let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "context", kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func write(_ state: PhoneSavedState) {
        var shared = PhoneSavedState()
        shared.deviceKeyID = state.deviceKeyID; shared.members = state.members; shared.catalogue = state.catalogue
        shared.settings = state.settings
        shared.pushTokenSHA256 = state.pushTokenSHA256
        guard let data = try? PropertyListEncoder().encode(shared) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Forgets what the extension was handed: the keychain keeps it when the app is removed.
    public func delete() { SecItemDelete(query as CFDictionary) }

    func read() -> PhoneSavedState? {
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? PropertyListDecoder().decode(PhoneSavedState.self, from: data)
    }
}

/// Time asked of iOS to finish one call after the app leaves the screen.
enum PhoneBackgroundTime {
    #if canImport(UIKit)
    @MainActor static func begin(_ name: String) -> UIBackgroundTaskIdentifier { UIApplication.shared.beginBackgroundTask(withName: name) }
    @MainActor static func end(_ task: UIBackgroundTaskIdentifier) { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
    #else
    static func begin(_ name: String) -> Int { 0 }
    static func end(_ task: Int) {}
    #endif
}

/// The notifications this app has shown for a request.
public enum PhoneNotifications {
    /// Removes a request's notification once it is answered or has ended, so none is left behind.
    public static func remove(_ requestID: String) {
        PhoneDiagnostics.log.note("notification", "removed", ["request": requestID])
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        center.getDeliveredNotifications { delivered in
            let same = delivered.filter { $0.request.content.threadIdentifier == requestID }.map(\.request.identifier)
            if !same.isEmpty { center.removeDeliveredNotifications(withIdentifiers: same) }
        }
        #endif
    }
}

extension Data {
    /// Base64url with no padding, as invitation links carry it.
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
