// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// How often agents asked for each password, and how Josh answered: for the
// Passwords table to show and sort. Counted once per request, from this Mac's
// own agents' leases and from what the relay shows this Mac of the others'.
// Kept in the app's container; it holds IDs and numbers, never a secret.

import Foundation

public struct PasswordUsage: Codable, Equatable, Sendable {
    public var asked = 0
    public var approved = 0
    public var denied = 0
    public var lastAsked: Date?
    public init() {}
}

@MainActor
public final class PasswordUsageLog {
    public enum Event: String, Codable, Sendable { case asked, approved, denied }

    private struct Saved: Codable {
        var usage: [String: PasswordUsage] = [:]
        /// Requests already counted, by request ID, with what was counted, so a request seen twice counts once.
        var counted: [String: [Event]] = [:]
    }

    private let file: URL
    private var saved: Saved

    public init(file: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/usage.json")) {
        self.file = file
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))) ?? Saved()
    }

    public var usage: [String: PasswordUsage] { saved.usage }

    public func note(_ event: Event, request: String, login: String, at date: Date = .now) {
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
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }
}
