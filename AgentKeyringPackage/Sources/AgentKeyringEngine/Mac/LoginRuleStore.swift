#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Security

/// Which logins agents may use, kept in the app's own keychain, where no other
/// program running as Josh can change them: a rule withdrawn with Touch ID
/// stays withdrawn.
@MainActor public final class LoginRuleStore {
    public static let protobufMagic = Data("AKRRUL02".utf8)

    private enum CodecError: Error {
        case invalidMagic
        case invalidUUID
    }

    private let read: () throws -> Data?
    private let write: (Data) throws -> Void

    public init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
        self.read = read
        self.write = write
    }

    public convenience init() {
        let keychain = DeviceKeychainStore(service: (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".rules.v2",
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        self.init(read: { try keychain.readKeychainItem("rules") }, write: { try keychain.writeKeychainItem($0, account: "rules") })
    }

    /// A rule this version does not know reads as Ask. Ask is kept too: an
    /// Ask set since must beat an older rule from another device. A keychain that cannot be read throws; rules
    /// this build cannot decode are logged and read as none, and the next save replaces them.
    public func loadAccessRules() throws -> [UUID: LoginRuleTimestampEntry] {
        guard let bytes = try read() else { return [:] }
        do { return try Self.decodeAccessRules(bytes) } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("rules", "undecodable, starting again", ["error": "\(error)"])
            return [:]
        }
    }

    private static func decodeAccessRules(_ bytes: Data) throws -> [UUID: LoginRuleTimestampEntry] {
        guard bytes.starts(with: Self.protobufMagic) else { throw CodecError.invalidMagic }
        let storedSet = try Agentkeyring_V2_StoredRuleSet(serializedBytes: Data(bytes.dropFirst(Self.protobufMagic.count)))
        var entries: [UUID: LoginRuleTimestampEntry] = [:]
        for stored in storedSet.entries {
            guard let id = UUID(uuidString: stored.loginID) else { throw CodecError.invalidUUID }
            let entry = LoginRuleTimestampEntry(LoginRule(storedRule: stored.rule), updatedAtMs: stored.updatedAtMs, actor: stored.actor)
            entries[id] = LoginRuleTimestampEntry.latest(entries[id], entry)
        }
        return entries
    }

    public func save(_ entries: [UUID: LoginRuleTimestampEntry]) throws {
        var ruleSet = Agentkeyring_V2_StoredRuleSet()
        ruleSet.entries = entries.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let entry = entries[id] else { return nil }
            var stored = Agentkeyring_V2_StoredRuleEntry()
            stored.loginID = id.uuidString
            stored.rule = entry.rule.storedRule
            stored.updatedAtMs = entry.updatedAtMs
            stored.actor = entry.actor
            return stored
        }
        try write(Self.protobufMagic + (try ruleSet.serializedData()))
    }
}
#endif
