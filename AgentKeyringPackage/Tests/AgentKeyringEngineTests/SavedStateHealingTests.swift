// Written by AI on 2026.11.28 by model claude opus 5.5.
//
// Saved state an earlier build left, which this one cannot decode, heals: the Mac's keys, its TLS identity, its
// vault files and its rules, and the iPhone's state file. A keychain or file the system will not let it read yet
// is kept as it is, and nothing is written over it.

@testable import AgentKeyringEngine
import AgentKeyringProtocol
@testable import AgentKeyringSealing
import Foundation
import Testing

@MainActor
struct SavedStateHealingTests {
    @Test("Keys an earlier build saved are deleted so setup makes new ones; a locked keychain throws and keeps them")
    func macKeysHealOrHold() throws {
        var deleted = false
        #expect(try MacKeys.savedKeys(read: { Data("AKRKEY01 earlier keys".utf8) }, delete: { deleted = true }) == nil)
        #expect(deleted)

        deleted = false
        #expect(throws: CocoaError.self) {
            try MacKeys.savedKeys(read: { throw CocoaError(.fileReadNoPermission) }, delete: { deleted = true })
        }
        #expect(!deleted)

        let saved = MacKeys.Saved(signing: Data([1]), opening: Data([2]), reply: Data([3]), receiving: Data([4]), mode: .devicePassword)
        #expect(try MacKeys.savedKeys(read: { try saved.stored() }, delete: { deleted = true })?.mode == .devicePassword)
        #expect(!deleted)
    }

    @Test("A TLS identity an earlier build saved is replaced with a new one; a locked keychain throws and keeps it")
    func tlsIdentityHealsOrHolds() throws {
        var stored: Data? = Data("AKRTLS01 earlier identity".utf8)
        let made = try DeviceTLSIdentity.loadOrCreate(read: { stored }, write: { stored = $0 })
        #expect(stored?.starts(with: Data("AKRTLS02".utf8)) == true)
        #expect(try DeviceTLSIdentity.loadOrCreate(read: { stored }, write: { _ in Issue.record("Should not rewrite") }).publicKeySPKI == made.publicKeySPKI)

        #expect(throws: CocoaError.self) {
            try DeviceTLSIdentity.loadOrCreate(read: { throw CocoaError(.fileReadNoPermission) }, write: { _ in Issue.record("Should not write") })
        }
    }

    @Test("Vault files an earlier build saved are removed and the vault starts empty; files it cannot read stay",
          arguments: ["pointer", "list", "sealed"])
    func vaultFilesHealOrHold(broken: String) async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MacVaultFileStore(directory: folder)
        try await store.save(StoredVaultSnapshot(id: UUID(), previousSnapshotID: nil, createdAt: .now, sourceExportedAt: .now, scope: .full,
                                                 exporterIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords",
                                                 items: [.testPassword], skippedCredentialCount: 0), sealed: [])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let name = switch broken {
        case "pointer": "current.generation"
        case "list": try #require(files.first { $0.hasPrefix("logins-") })
        default: try #require(files.first { $0.hasPrefix("sealed-") })
        }
        let file = folder.appending(path: name)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        await #expect(throws: (any Error).self) {
            if broken == "sealed" { _ = try await store.sealed() } else { _ = try await store.loadCurrent() }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3)

        try Data("an earlier build's bytes".utf8).write(to: file)
        if broken == "sealed" { #expect(try await store.sealed().isEmpty) } else { #expect(try await store.loadCurrent() == nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(try await store.loadCurrent() == nil)
    }

    @Test("Rules an earlier build saved read as none and are replaced; rules a locked keychain holds are never written over")
    func rulesHealOrHold() throws {
        var saved: Data? = Data("AKRRUL01 earlier rules".utf8)
        let healed = CredentialAccessController(store: LoginRuleStore(read: { saved }, write: { saved = $0 }))
        #expect(healed.entries.isEmpty && !healed.savedRulesLocked && healed.errorMessage == nil)

        let login = UUID()
        let blocked = [login: LoginRuleTimestampEntry(.blocked, updatedAtMs: 5, actor: "mac")]
        try LoginRuleStore(read: { nil }, write: { saved = $0 }).save(blocked)
        let kept = saved
        var locked = true
        var writes = 0
        let controller = CredentialAccessController(store: LoginRuleStore(
            read: { if locked { throw CocoaError(.fileReadNoPermission) }; return saved },
            write: { writes += 1; saved = $0 }))
        #expect(controller.savedRulesLocked)

        // A peer's catalogue arrives at launch, worked out from no rules: it is refused, and taken again later.
        let fromPeer = [login: LoginRuleTimestampEntry(.automatic, updatedAtMs: 1, actor: "iphone")]
        #expect(throws: CocoaError.self) { try controller.adopt(fromPeer) }
        #expect(writes == 0 && saved == kept)

        locked = false
        #expect(throws: AccessRulesReadAgain.self) { try controller.adopt(fromPeer) }
        #expect(writes == 0 && saved == kept)
        #expect(controller.rule(for: login) == .blocked && !controller.savedRulesLocked && controller.errorMessage == nil)
    }

    @Test("An iPhone state file an earlier build saved starts first run again, with the extension and the Watch told")
    func phoneStateHeals() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("an earlier build's state".utf8).write(to: folder.appending(path: "phone-v2.pb"))
        try "1000".write(to: folder.appending(path: "watch-reset"), atomically: true, encoding: .utf8)
        let shared = PhoneSharedContext.memory()
        shared.writeSnapshot(PhoneSharedSnapshot(deviceKeyID: "old-iphone", members: Data([1]), catalogue: Data([2])))

        let phone = PhoneKeyringEngine(directory: folder, shared: shared, keys: NoKeys(), identity: { throw CancellationError() }, cloud: nil)

        #expect(!phone.stateFileLocked && phone.state.deviceKeyID == nil)
        #expect(try PhoneSavedState.decodeProtobuf(Data(contentsOf: folder.appending(path: "phone-v2.pb"))) == PhoneSavedState())
        #expect(shared.readSnapshot() == nil)
        #expect(phone.watchResetAt > 1000)
    }
}
