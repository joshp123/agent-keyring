import Foundation

/// The record of agents' leases: a private file in the app's container. It
/// holds no secrets, and editing it gains nothing: an approved login lives
/// only in memory, and an Automatic one opens only from its sealed copy.
@MainActor
public final class LeasePersistence {
    private let file: URL

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/leases")) {
        file = directory.appending(path: "leases.plist")
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    public func save(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
