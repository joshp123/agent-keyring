// Written by AI on 2026.11.24 by model claude opus 5.5.
//
// Apple Watch's own copy of every password it may approve, sealed to its
// opening key by its iPhone (or by the Mac, and passed on by the iPhone) and
// sent with WatchConnectivity's transferFile, a whole generation at a time
// (keyring.proto, WatchCopies). Kept in one file in the app's container:
// ciphertext that only this Watch's Secure Enclave opens. No computer or relay
// ever holds them.

import AgentKeyringProtocol
import Foundation
import OSLog

public struct WatchCopiesStore: Sendable {
    public enum StageResult: Equatable, Sendable {
        case applied
        case stagedWaitingForCatalogue
        case older
        case writeFailed
    }

    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.agentkeyring.app", category: "WatchCopies")
    let file: URL
    let pendingFile: URL

    public init(file: URL = URL.applicationSupportDirectory.appending(path: "watch-copies.pb")) {
        self.file = file
        self.pendingFile = file.deletingLastPathComponent().appending(path: "watch-copies-pending.pb")
    }

    public func readWatchCopies() -> Agentkeyring_V2_WatchCopies {
        Self.lock.withLock { readUnlocked() }
    }

    private func readUnlocked() -> Agentkeyring_V2_WatchCopies {
        (try? Data(contentsOf: file)).flatMap { try? Agentkeyring_V2_WatchCopies(serializedBytes: $0) } ?? Agentkeyring_V2_WatchCopies()
    }

    private func readPendingUnlocked() -> Agentkeyring_V2_WatchCopies? {
        (try? Data(contentsOf: pendingFile)).flatMap { try? Agentkeyring_V2_WatchCopies(serializedBytes: $0) }
    }

    /// Takes a generation from the iPhone in place of every copy held, unless an older one: true if taken.
    @discardableResult
    public func replace(with next: Agentkeyring_V2_WatchCopies) -> Bool {
        Self.lock.withLock {
            guard next.generation > readUnlocked().generation else { return false }
            return commit(next)
        }
    }

    /// Commits a received batch when the local Catalogue is at least `next.catalogueRevision`;
    /// otherwise stages it without bumping the generation floor or deleting copies against an older Catalogue.
    @discardableResult
    public func stageOrReplace(with next: Agentkeyring_V2_WatchCopies, catalogue: Catalogue?) -> StageResult {
        Self.lock.withLock {
            let held = readUnlocked()
            guard next.generation > held.generation else { return .older }
            if next.catalogueRevision > 0, (catalogue?.revision ?? 0) < next.catalogueRevision {
                if let existingPending = readPendingUnlocked(), existingPending.generation >= next.generation {
                    return .older
                }
                return persist(next, to: pendingFile) ? .stagedWaitingForCatalogue : .writeFailed
            }
            var committed = next
            if let catalogue {
                committed.copies = Self.pruned(committed.copies, catalogue: catalogue)
            }
            return commit(committed) ? .applied : .writeFailed
        }
    }

    /// Commits a previously staged batch once a signed Catalogue at or past its required revision arrives.
    /// Returns the committed generation if applied, or nil if nothing was ready.
    @discardableResult
    public func applyPendingIfReady(catalogue: Catalogue) -> UInt64? {
        Self.lock.withLock {
            guard let pending = readPendingUnlocked() else { return nil }
            guard catalogue.revision >= pending.catalogueRevision else { return nil }
            guard pending.generation > readUnlocked().generation else { return nil }
            var committed = pending
            committed.copies = Self.pruned(committed.copies, catalogue: catalogue)
            return commit(committed) ? committed.generation : nil
        }
    }

    /// Drops every copy the signed Catalogue no longer allows (a password Blocked, deleted or copied again),
    /// at once, before the iPhone's next generation arrives.
    func prune(catalogue: Catalogue?) {
        // No catalogue yet says nothing about which copies go.
        guard let catalogue else { return }
        Self.lock.withLock {
            var held = readUnlocked()
            let before = held.copies.count
            held.copies = Self.pruned(held.copies, catalogue: catalogue)
            if held.copies.count != before { persist(held, to: file) }
        }
    }

    private static func pruned(_ copies: [SealedLogin], catalogue: Catalogue) -> [SealedLogin] {
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        return copies.filter { copy in
            guard let login = listed[copy.loginID] else { return false }
            return login.holdsSecret && login.version == copy.version
        }
    }

    /// This Watch's copy of a login, of the version the signed Catalogue lists.
    public func copy(of login: Agentkeyring_V2_Login, for keyID: String) -> SealedLogin? {
        readWatchCopies().copies.first { $0.loginID == login.loginID && $0.openerID == keyID && $0.version == login.version }
    }

    /// Removed from the list: every copy goes. The generation stays as a floor, so a generation sent before
    /// the removal and arriving after it is older and never taken.
    func deleteWatchCopies() {
        Self.lock.withLock {
            var floor = Agentkeyring_V2_WatchCopies()
            floor.generation = max(readUnlocked().generation, readPendingUnlocked()?.generation ?? 0)
            _ = commit(floor)
        }
    }

    private func commit(_ copies: Agentkeyring_V2_WatchCopies) -> Bool {
        guard persist(copies, to: file) else { return false }
        if (readPendingUnlocked()?.generation ?? 0) <= copies.generation {
            try? FileManager.default.removeItem(at: pendingFile)
        }
        return true
    }

    @discardableResult
    private func persist(_ copies: Agentkeyring_V2_WatchCopies, to target: URL) -> Bool {
        do {
            try write(copies, to: target)
            return true
        } catch {
            Self.logger.error("Could not save Watch copies: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func write(_ copies: Agentkeyring_V2_WatchCopies, to target: URL) throws {
        let data = try copies.serializedData()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(watchOS)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: target, options: .atomic)
        #endif
    }
}
