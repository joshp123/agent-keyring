import AgentKeyringRelaySupport
import Foundation
import Security

/// Which logins agents may use, kept in the app's own keychain, where no other
/// program running as Josh can change them: a rule withdrawn with Touch ID
/// stays withdrawn.
@MainActor public final class CredentialAccessPolicyStore {
    private struct Record: Codable, Equatable {
        let credentialID: UUID
        let policy: String
    }

    private struct FileContents: Codable {
        let version: Int
        let records: [Record]
    }

    private let read: () throws -> Data?
    private let write: (Data) throws -> Void

    public init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
        self.read = read
        self.write = write
    }

    public convenience init() {
        let keychain = RelayKeychain(service: (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".rules.v2",
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        self.init(read: { try keychain.read("rules") }, write: { try keychain.write($0, account: "rules") })
    }

    /// A rule this version does not know reads as Ask.
    public func load() throws -> [UUID: CredentialAccessPolicy] {
        guard let bytes = try read() else { return [:] }
        let contents = try JSONDecoder().decode(FileContents.self, from: bytes)
        return Dictionary(contents.records.map { ($0.credentialID, CredentialAccessPolicy(rawValue: $0.policy) ?? .ask) },
            uniquingKeysWith: { _, last in last }).filter { $0.value != .ask }
    }

    public func save(_ policies: [UUID: CredentialAccessPolicy]) throws {
        let records = policies.filter { $0.value != .ask }.map { Record(credentialID: $0.key, policy: $0.value.rawValue) }
            .sorted { $0.credentialID.uuidString < $1.credentialID.uuidString }
        try write(JSONEncoder().encode(FileContents(version: 4, records: records)))
    }
}
