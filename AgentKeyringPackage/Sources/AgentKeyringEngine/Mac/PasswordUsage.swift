// Written by AI on 2026.11.20 by model claude opus 5.5; protobuf storage on 2026.11.27 by model claude opus 5.5.
//
// How often agents asked for each password, and how Josh answered: for the
// Passwords table to show and sort. Counted once per request, from this Mac's
// own agents' leases and from what the relay shows this Mac of the others'.
// Kept in the app's container as `StoredPasswordUsage`; it holds IDs and
// numbers, never a secret.

#if os(macOS)
import AgentKeyringProtocol
import Foundation

public struct PasswordUsage: Equatable, Sendable {
    public var asked = 0
    public var approved = 0
    public var denied = 0
    var lastAsked: Date?
    public init() {}
}

public enum PasswordUsageEvent: Sendable { case asked, approved, denied }

@MainActor
public final class PasswordUsageLog {

    private struct Saved {
        var usage: [String: PasswordUsage] = [:]
        /// Requests already counted, by request ID, with what was counted, so a request seen twice counts once.
        var counted: [String: [PasswordUsageEvent]] = [:]
    }

    private let file: URL
    private var saved: Saved

    public init(file: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/usage.pb")) {
        self.file = file
        saved = (try? Data(contentsOf: file)).flatMap { try? Agentkeyring_V2_StoredPasswordUsage(serializedBytes: $0) }
            .map(Self.saved(from:)) ?? Saved()
    }

    public var usage: [String: PasswordUsage] { saved.usage }

    public func noteUsage(_ event: PasswordUsageEvent, request: String, login: String, at date: Date = .now) {
        guard !request.isEmpty, !login.isEmpty, saved.counted[request]?.contains(event) != true else { return }
        saved.counted[request, default: []].append(event)
        var entry = saved.usage[login] ?? PasswordUsage()
        switch event {
        case .asked: entry.asked += 1; entry.lastAsked = date
        case .approved: entry.approved += 1
        case .denied: entry.denied += 1
        }
        saved.usage[login] = entry
        if saved.counted.count > 5000 { saved.counted = [request: saved.counted[request] ?? []] }
        write()
    }

    func clearUsageLog() {
        saved = Saved()
        try? FileManager.default.removeItem(at: file)
    }

    private func write() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.stored(saved).serializedData().write(to: file, options: .atomic)
    }

    private static func saved(from proto: Agentkeyring_V2_StoredPasswordUsage) -> Saved {
        var saved = Saved()
        saved.usage = proto.usage.mapValues { stored in
            var usage = PasswordUsage()
            usage.asked = Int(stored.asked)
            usage.approved = Int(stored.approved)
            usage.denied = Int(stored.denied)
            usage.lastAsked = stored.hasLastAskedUnixSeconds ? Date(timeIntervalSince1970: stored.lastAskedUnixSeconds) : nil
            return usage
        }
        saved.counted = proto.counted.mapValues { $0.events.compactMap(event(from:)) }
        return saved
    }

    private static func stored(_ saved: Saved) -> Agentkeyring_V2_StoredPasswordUsage {
        var proto = Agentkeyring_V2_StoredPasswordUsage()
        proto.usage = saved.usage.mapValues { usage in
            var stored = Agentkeyring_V2_StoredPasswordUsage.LoginUsage()
            stored.asked = UInt64(max(0, usage.asked))
            stored.approved = UInt64(max(0, usage.approved))
            stored.denied = UInt64(max(0, usage.denied))
            if let lastAsked = usage.lastAsked { stored.lastAskedUnixSeconds = lastAsked.timeIntervalSince1970 }
            return stored
        }
        proto.counted = saved.counted.mapValues { events in
            var stored = Agentkeyring_V2_StoredPasswordUsage.CountedEvents()
            stored.events = events.map(storedEvent)
            return stored
        }
        return proto
    }

    private static func event(from stored: Agentkeyring_V2_StoredPasswordUsage.Event) -> PasswordUsageEvent? {
        switch stored {
        case .asked: .asked
        case .approved: .approved
        case .denied: .denied
        case .unspecified, .UNRECOGNIZED: nil
        }
    }

    private static func storedEvent(_ event: PasswordUsageEvent) -> Agentkeyring_V2_StoredPasswordUsage.Event {
        switch event {
        case .asked: .asked
        case .approved: .approved
        case .denied: .denied
        }
    }
}
#endif
