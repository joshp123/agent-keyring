import Foundation

/// Unsigned: these IDs can only block release, never grant it or trust a device.
struct PendingIPhoneBlocks {
    let fileURL: URL

    init(rulesFileURL: URL) {
        fileURL = rulesFileURL.deletingPathExtension().appendingPathExtension("iphone-blocks.plist")
    }

    func load() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return Set(try PropertyListDecoder().decode([UUID].self, from: Data(contentsOf: fileURL)))
    }

    func save(_ credentialIDs: Set<UUID>) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(credentialIDs.sorted { $0.uuidString < $1.uuidString })
            .write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
