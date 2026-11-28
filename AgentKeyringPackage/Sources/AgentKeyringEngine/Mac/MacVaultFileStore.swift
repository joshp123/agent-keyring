// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// What the Mac keeps of the imported logins: the import with every secret
// removed (names, sites, accounts, and which fields each login has, so the next
// import keeps each login's ID), and the logins sealed to each key that may
// open them. Nothing here is readable without one of those keys.

#if os(macOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

public actor MacVaultFileStore {
    private let directory: URL
    private var pointerURL: URL { directory.appending(path: "current.generation") }

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/logins")) {
        self.directory = directory
    }

    /// What `current.generation` names: an import with its sealed copies (`pair:<token>`), or, before the first
    /// import, sealed copies alone (`sealed:<token>`).
    private enum Generation {
        case pair(String)
        case sealedOnly(String)

        var token: String {
            switch self {
            case let .pair(token), let .sealedOnly(token): token
            }
        }

        var pointer: String {
            switch self {
            case let .pair(token): "pair:" + token
            case let .sealedOnly(token): "sealed:" + token
            }
        }
    }

    /// What `current.generation` names. One this build cannot decode starts the vault again.
    private func activeGeneration() throws -> Generation? {
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        let pointer = String(decoding: try Data(contentsOf: pointerURL), as: UTF8.self)
        let parts = pointer.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, UUID(uuidString: parts[1]) != nil {
            if parts[0] == "pair" { return .pair(parts[1]) }
            if parts[0] == "sealed" { return .sealedOnly(parts[1]) }
        }
        try startVaultAgain(because: CocoaError(.fileReadCorruptFile))
        return nil
    }

    /// Files a disk read but this build cannot decode: logged, removed, and the vault starts empty, as before the
    /// first import. A file that cannot be read at all throws where it is read, and nothing is removed.
    private func startVaultAgain(because error: Error) throws {
        KeyringDiagnosticLog.mac.noteDeviceEvent("vault", "undecodable, starting again", ["error": "\(error)"])
        try deleteVaultFiles()
    }

    private func activeGenerationToken() throws -> String? { try activeGeneration()?.token }

    private func listURL(for token: String) -> URL {
        directory.appending(path: "logins-\(token).pb")
    }

    private func sealedURL(for token: String) -> URL {
        directory.appending(path: "sealed-\(token).pb")
    }

    /// The last import, with no secrets in it. Nil before the first import,
    /// even if sealed copies arrived first (a computer joined before any copy
    /// from Passwords): that generation has sealed copies and no list.
    /// An import whose list is missing throws: only a generation of sealed copies alone has none.
    public func loadCurrent() throws -> StoredVaultSnapshot? {
        guard case let .pair(token)? = try activeGeneration() else { return nil }
        let bytes = try Data(contentsOf: listURL(for: token))
        do { return try StoredVaultSnapshot.decodeProtobuf(bytes) } catch {
            try startVaultAgain(because: error)
            return nil
        }
    }

    public func loadCurrentMetadata() throws -> MacVaultMetadata? {
        try loadCurrent()?.metadata
    }

    public func sealed() throws -> [Agentkeyring_V2_SealedLogin] {
        guard let token = try activeGenerationToken() else { return [] }
        let bytes = try Data(contentsOf: sealedURL(for: token))
        do { return try Agentkeyring_V2_SealedLogins(serializedBytes: bytes).logins } catch {
            try startVaultAgain(because: error)
            return []
        }
    }

    /// Saves an import: its secrets are dropped here, and only the sealed copies keep them.
    public func save(_ snapshot: StoredVaultSnapshot, sealed: [Agentkeyring_V2_SealedLogin]) throws {
        try commitPair(snapshot: snapshot, sealed: sealed)
    }

    /// Saves an import and atomically transforms the sealed copies in one actor turn so concurrent
    /// uploads or device fills cannot be overwritten by an import reading an earlier snapshot.
    public func save(_ snapshot: StoredVaultSnapshot,
                     updatingSealed transform: @Sendable ([Agentkeyring_V2_SealedLogin]) -> [Agentkeyring_V2_SealedLogin]) throws {
        let existing = try sealed()
        let updated = transform(existing)
        try commitPair(snapshot: snapshot, sealed: updated)
    }

    /// Crash-atomic two-file commit: writes `sealed-<gen>.pb` and `logins-<gen>.pb` first, then
    /// atomically swaps `current.generation` in one rename so a crash at any point always reopens
    /// a matched `(logins, sealed)` pair.
    private func commitPair(snapshot: StoredVaultSnapshot, sealed: [Agentkeyring_V2_SealedLogin]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let listData = try snapshot.redacted.encodeProtobuf()
        var all = Agentkeyring_V2_SealedLogins()
        all.logins = sealed
        let sealedData = try all.serializedData()

        let token = UUID().uuidString
        let nextSealed = sealedURL(for: token)
        let nextList = listURL(for: token)
        do {
            try sealedData.write(to: nextSealed, options: .atomic)
            try listData.write(to: nextList, options: .atomic)
            try Data(Generation.pair(token).pointer.utf8).write(to: pointerURL, options: .atomic)
        } catch {
            if (try? activeGenerationToken()) != token {
                try? fm.removeItem(at: nextSealed)
                try? fm.removeItem(at: nextList)
            }
            throw error
        }
        cleanupOldGenerations(keeping: token)
    }

    /// Replaces the sealed copies of the current generation. Before the first
    /// import there is none: a new generation is committed that holds only
    /// sealed copies, so every saved file is under a committed token.
    public func replaceSealed(_ sealed: [Agentkeyring_V2_SealedLogin]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var all = Agentkeyring_V2_SealedLogins()
        all.logins = sealed
        let data = try all.serializedData()
        if let token = try activeGenerationToken() {
            try data.write(to: sealedURL(for: token), options: .atomic)
            return
        }
        let token = UUID().uuidString
        let next = sealedURL(for: token)
        do {
            try data.write(to: next, options: .atomic)
            try Data(Generation.sealedOnly(token).pointer.utf8).write(to: pointerURL, options: .atomic)
        } catch {
            if (try? activeGenerationToken()) != token { try? FileManager.default.removeItem(at: next) }
            throw error
        }
        cleanupOldGenerations(keeping: token)
    }

    private func cleanupOldGenerations(keeping activeToken: String) {
        let fm = FileManager.default
        let keepNames: Set<String> = [
            pointerURL.lastPathComponent,
            listURL(for: activeToken).lastPathComponent,
            sealedURL(for: activeToken).lastPathComponent,
        ]
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where !keepNames.contains(item.lastPathComponent) {
            let name = item.lastPathComponent
            if name.hasPrefix("logins-") || name.hasPrefix("sealed-")
                || name.hasPrefix(".logins-") || name.hasPrefix(".sealed-") {
                try? fm.removeItem(at: item)
            }
        }
    }

    /// Atomically transforms the sealed copy list in a single actor turn so concurrent fills
    /// or uploads cannot read stale snapshots and overwrite each other.
    @discardableResult
    func updateSealed(_ transform: @Sendable ([Agentkeyring_V2_SealedLogin]) -> [Agentkeyring_V2_SealedLogin]) throws -> [Agentkeyring_V2_SealedLogin] {
        let existing = try sealed()
        let updated = transform(existing)
        try replaceSealed(updated)
        return updated
    }

    /// Atomically merges a batch of sealed copies for one opener in a single actor turn so
    /// concurrent device fills cannot read stale snapshots and overwrite each other's copies.
    func mergeSealed(replacingOpener openerID: String, with incoming: [Agentkeyring_V2_SealedLogin]) throws {
        let ids = Set(incoming.map(\.loginID))
        try updateSealed { existing in
            existing.filter { $0.openerID != openerID || !ids.contains($0.loginID) } + incoming
        }
    }

    /// Removes all saved logins and sealed copies from disk.
    func deleteVaultFiles() throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let name = item.lastPathComponent
            if name == pointerURL.lastPathComponent
                || name.hasPrefix("logins-") || name.hasPrefix("sealed-")
                || name.hasPrefix(".logins-") || name.hasPrefix(".sealed-") {
                try fm.removeItem(at: item)
            }
        }
    }
}
#endif
