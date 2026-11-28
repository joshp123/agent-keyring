// Written by AI on 2026.11.20 by model Claude Opus 5.5; edited on 2026.11.28 by model claude opus 5.5.
//
// What each app and its notification extension did, and why, one line each:
// "<UTC time> <device> <part> <event> key=value ...". The newest 500 lines stay
// in the app's container, so an agent can read them without a cable, and go to
// the unified log too; `agent-keyring logs` gathers them. A notification
// extension runs in its own container, so it leaves its lines in the keychain
// group it shares with its app, and the app takes them into its ring. Lines
// carry IDs, states and reasons: never a password, a key, sealed bytes, a
// token, or a site, account or agent's reason.

import AgentKeyringProtocol
import Foundation
import OSLog
import Security
import Synchronization

public final class KeyringDiagnosticLog: Sendable {
    public static let keep = 500

    /// The Mac app's ring. A test run, which is not sandboxed, keeps it in memory: on disk it would land in
    /// his home folder.
    public static let mac = KeyringDiagnosticLog(device: "mac", file: {
        let file = URL.applicationSupportDirectory.appending(path: "AgentKeyring/log.txt")
        return file.path.contains("/Library/Containers/") ? file : nil
    }())
    /// The iPhone app's ring, or its notification extension's.
    public static let iPhone = KeyringDiagnosticLog(device: runsInExtension ? "iphone-notice" : "iphone")
    /// The Apple Watch app's ring, or its notification extension's.
    public static let watch = KeyringDiagnosticLog(device: runsInExtension ? "watch-notice" : "watch")

    private static var runsInExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    /// None on a Mac, where the iPhone's and the Watch's rings run only in tests: on disk they would land in his
    /// home folder.
    public static var defaultFile: URL? {
        #if os(macOS)
        nil
        #else
        URL.cachesDirectory.appending(path: "agent-keyring.log")
        #endif
    }

    /// "mac", "iphone", "iphone-notice", "watch" or "watch-notice".
    public let device: String
    private let file: URL?
    private let logger: Logger
    /// The ring, read from `file` on first use. Every write to the file happens under this lock.
    private let ring = Mutex<[String]?>(nil)

    public init(device: String, file: URL? = KeyringDiagnosticLog.defaultFile) {
        self.device = device
        self.file = file
        logger = Logger(subsystem: "com.agentkeyring.app", category: device)
    }

    /// Where a notification extension leaves its lines for its app.
    private var inbox: DiagnosticLogInbox? { device.hasSuffix("-notice") ? DiagnosticLogInbox() : nil }

    /// `2026-11-20T01:15:53.139Z iphone answer sent request=2c3cc4a1 choice=approve`
    public static func line(at date: Date = .now, device: String, part: String, event: String, _ fields: KeyValuePairs<String, String> = [:]) -> String {
        let pairs = fields.map { key, value in "\(key)=\(quoted(value))" }
        return ([timestamp(date), device, part, event] + pairs).joined(separator: " ")
    }

    /// Every line starts with it, so lines sort and compare by time as text.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    static func quoted(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.isEmpty || flat.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" })
            ? "\"\(flat.replacingOccurrences(of: "\"", with: "'"))\"" : flat
    }

    public func noteDeviceEvent(_ part: String, _ event: String, _ fields: KeyValuePairs<String, String> = [:]) {
        let line = Self.line(device: device, part: part, event: event, fields)
        logger.notice("\(line, privacy: .public)")
        if let inbox { inbox.put(line) } else { append([line]) }
    }

    /// Takes in what the notification extension left since the app last looked.
    public func collect() {
        guard inbox == nil else { return }
        mergeLogLines(DiagnosticLogInbox().take())
    }

    /// The newest lines, oldest first.
    public func lines(last count: Int = KeyringDiagnosticLog.keep) -> [String] {
        ring.withLock { ring in Array(loaded(&ring).suffix(count)) }
    }

    /// The lines from `since` (Unix seconds, 0 for all) that name `request`, if given.
    public func lines(since: Int64, request: String) -> [String] {
        let from = since > 0 ? Self.timestamp(Date(timeIntervalSince1970: TimeInterval(since))) : ""
        return lines(last: .max).filter { $0 >= from && (request.isEmpty || $0.contains(request)) }
    }

    /// Adds lines another device sent (the Watch's, on the iPhone), those not already here.
    public func mergeLogLines(_ incoming: [String]) {
        ring.withLock { ring in
            let have = Set(loaded(&ring))
            write(incoming.filter { !have.contains($0) }, to: &ring)
        }
    }

    private func append(_ new: [String]) {
        ring.withLock { ring in
            _ = loaded(&ring)
            write(new, to: &ring)
        }
    }

    private func loaded(_ ring: inout [String]?) -> [String] {
        if let ring { return ring }
        let read = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { $0.split(separator: "\n").map(String.init) } ?? []
        ring = Array(read.suffix(Self.keep))
        return ring!
    }

    /// Appends to the file, and rewrites it to the newest `keep` once it holds a fifth more.
    private func write(_ new: [String], to ring: inout [String]?) {
        guard !new.isEmpty else { return }
        var all = ring ?? []
        all += new
        let trim = all.count > Self.keep + Self.keep / 5
        if trim { all = Array(all.suffix(Self.keep)) }
        ring = all
        guard let file else { return }
        if trim {
            try? Data(all.map { $0 + "\n" }.joined().utf8).write(to: file, options: .atomic)
            return
        }
        let data = Data(new.map { $0 + "\n" }.joined().utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }
}

/// A notification extension's recent lines, in one keychain item of the group it shares with its app.
struct DiagnosticLogInbox {
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
              let log = try? Agentkeyring_V2_StoredDeviceLog(serializedBytes: data) else { return [] }
        return log.lines
    }

    func put(_ line: String) {
        var log = Agentkeyring_V2_StoredDeviceLog()
        log.lines = Array((read() + [line]).suffix(Self.keep))
        guard let data = try? log.serializedData() else { return }
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
