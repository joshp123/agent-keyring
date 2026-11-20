// Written by AI on 2026.11.20 by model Claude Opus 5.5.
//
// What the iPhone and Apple Watch apps and their notification extensions did,
// and why, one line each, kept in a ring of the last 500 lines in the app's
// container, so that an agent can read it without a cable. A notification
// extension runs in its own container, so it leaves its lines in the keychain
// group it shares with its app, and the app takes them into its ring. Never a
// password, sealed copy, token, key, account, site or agent's reason.

import Foundation
import OSLog
import Security

public struct DeviceLog: Sendable {
    public static let keep = 500

    /// "iphone", "iphone-notice", "watch" or "watch-notice".
    public let device: String
    private let file: URL?

    public init(device: String, file: URL? = DeviceLog.defaultFile) {
        self.device = device
        self.file = file
    }

    public static var defaultFile: URL? { URL.cachesDirectory.appending(path: "agent-keyring.log") }

    /// Where a notification extension leaves its lines for its app.
    private var inbox: DeviceLogInbox? { device.hasSuffix("-notice") ? DeviceLogInbox() : nil }

    /// `2026-11-20T01:15:53.139Z iphone answer sent request=2c3cc4a1 choice=approve`
    public static func line(at date: Date = .now, device: String, part: String, event: String, _ fields: KeyValuePairs<String, String> = [:]) -> String {
        let time = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
        let pairs = fields.map { key, value in "\(key)=\(quoted(value))" }
        return ([time, device, part, event] + pairs).joined(separator: " ")
    }

    static func quoted(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.contains(" ") || flat.isEmpty ? "\"\(flat.replacingOccurrences(of: "\"", with: "'"))\"" : flat
    }

    public func note(_ part: String, _ event: String, _ fields: KeyValuePairs<String, String> = [:]) {
        let line = Self.line(device: device, part: part, event: event, fields)
        Logger(subsystem: "com.joshpalmer.AgentKeyring", category: device).notice("\(line, privacy: .public)")
        if let inbox { inbox.put(line) } else { append([line]) }
    }

    /// Takes in what the notification extension left since the app last looked.
    public func collect() {
        guard inbox == nil else { return }
        merge(DeviceLogInbox().take())
    }

    /// The newest lines, oldest first.
    public func lines(last count: Int = DeviceLog.keep) -> [String] {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").map(String.init).suffix(count))
    }

    /// Adds lines another device sent (the Watch's, on the iPhone), those not already here.
    public func merge(_ incoming: [String]) {
        let have = Set(lines())
        append(incoming.filter { !have.contains($0) })
    }

    private func append(_ new: [String]) {
        guard let file, !new.isEmpty else { return }
        let data = Data(new.map { $0 + "\n" }.joined().utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
        // Trimmed now and then, not on every line: the ring may hold up to a fifth more for a moment.
        let all = lines(last: .max)
        if all.count > Self.keep + Self.keep / 5 {
            try? Data(all.suffix(Self.keep).map { $0 + "\n" }.joined().utf8).write(to: file, options: .atomic)
        }
    }
}

/// A notification extension's recent lines, in one keychain item of the group it shares with its app.
struct DeviceLogInbox {
    static let keep = 100
    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.joshpalmer.AgentKeyring.log-inbox",
                                    kSecAttrAccount as String: "lines", kSecUseDataProtectionKeychain as String: true]
        if let group = Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String, !group.isEmpty,
           !group.hasPrefix("$") { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private func read() -> [String] {
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let lines = try? PropertyListDecoder().decode([String].self, from: data) else { return [] }
        return lines
    }

    func put(_ line: String) {
        guard let data = try? PropertyListEncoder().encode(Array((read() + [line]).suffix(Self.keep))) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func take() -> [String] {
        let lines = read()
        if !lines.isEmpty { SecItemDelete(query as CFDictionary) }
        return lines
    }
}
