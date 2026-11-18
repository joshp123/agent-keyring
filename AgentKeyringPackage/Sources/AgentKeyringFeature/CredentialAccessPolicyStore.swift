import Foundation

/// Which logins agents may use: a plain file in the app's container. It needs
/// no signature: switching a login to Automatic in this file alone does
/// nothing, because an Automatic login opens only from a copy sealed to this
/// Mac's receiving key, and that copy is made only after Josh's Touch ID.
@MainActor public final class CredentialAccessPolicyStore {
    private struct Record: Codable, Equatable {
        let credentialID: UUID
        let policy: CredentialAccessPolicy
    }

    private struct FileContents: Codable {
        let version: Int
        let records: [Record]
    }

    public let fileURL: URL

    public init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/access-policies.json")) {
        self.fileURL = fileURL
    }

    public func load() throws -> [UUID: CredentialAccessPolicy] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let contents = try JSONDecoder().decode(FileContents.self, from: Data(contentsOf: fileURL))
        return Dictionary(contents.records.map { ($0.credentialID, $0.policy) }, uniquingKeysWith: { _, last in last })
    }

    public func save(_ policies: [UUID: CredentialAccessPolicy]) throws {
        let records = policies.filter { $0.value != .ask }.map { Record(credentialID: $0.key, policy: $0.value) }
            .sorted { $0.credentialID.uuidString < $1.credentialID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try encoder.encode(FileContents(version: 3, records: records)).write(to: fileURL, options: .atomic)
    }
}
