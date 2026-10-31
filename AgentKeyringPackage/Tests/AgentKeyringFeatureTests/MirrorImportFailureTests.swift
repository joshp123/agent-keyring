import AuthenticationServices
import AgentKeyringTestSupport
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Credential import failures")
struct MirrorImportFailureTests {
    @MainActor
    @Test("Import reports whether a refresh committed and retains the other logins", arguments: [false, true])
    func refreshCommitBoundary(failBeforeCommit: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyringImport-\(UUID())")
        let vaultDirectory = directory.appendingPathComponent("vault")
        let settingsName = "KeyringImport-\(UUID())"
        let settings = try #require(UserDefaults(suiteName: settingsName))
        settings.set(false, forKey: "includeExampleCredential")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vaultDirectory.path)
            try? FileManager.default.removeItem(at: directory)
            settings.removePersistentDomain(forName: settingsName)
        }
        let store = EncryptedSnapshotStore(directoryURL: vaultDirectory,
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x5A, count: 32)))
        let original = generation()
        try await store.save(original)
        let model = MirrorAppModel(store: store, credentialImporter: SyntheticRefreshImporter(),
            bridge: AgentBridgeDirectory(rootURL: directory.appendingPathComponent("bridge")),
            accessControl: CredentialAccessController(store: CredentialAccessPolicyStore(
                fileURL: directory.appendingPathComponent("rules.json"), signer: FakeAccessRulesSigner())),
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(
                directory: directory.appendingPathComponent("authority"),
                checkpointService: settingsName)), settings: settings)
        model.status = original.safeStatus
        if failBeforeCommit {
            // Payloads can be written; the atomic current-pointer replacement cannot.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vaultDirectory.path)
        }
        await model.importCredentials(token: UUID())
        let saved = try #require(try await store.loadCurrent())
        #expect(saved.items.count == 2)
        #expect(saved.items.contains(original.items[1]))
        #expect(model.status == saved.safeStatus)
        if failBeforeCommit {
            #expect(saved == original)
            #expect(model.notice?.kind == .error)
            #expect(model.notice?.text.contains("existing mirror was not changed") == true)
        } else {
            #expect(saved.id != original.id)
            #expect(saved.items.first { $0.id == original.items[0].id }?.credentials
                == [.password(userName: "account", password: "NEW-SYNTHETIC-PASSWORD")])
            #expect(model.notice?.kind == .warning)
            #expect(model.notice?.text.contains("Your logins were saved") == true)
            #expect(model.notice?.text.contains("was not changed") == false)
        }
    }

    @MainActor
    @Test("A rejected import token keeps the current encrypted mirror")
    func rejectedTokenKeepsCurrentMirror() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKeyringImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = EncryptedSnapshotStore(
            directoryURL: directory,
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x5A, count: 32))
        )
        let original = generation()
        try await store.save(original)
        let settingsName = "MirrorImportFailureTests-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: settingsName))
        defer { settings.removePersistentDomain(forName: settingsName) }
        settings.set(false, forKey: "includeExampleCredential")
        let model = MirrorAppModel(
            store: store,
            credentialImporter: RejectedTokenImporter(),
            bridge: AgentBridgeDirectory(rootURL: directory.appendingPathComponent("bridge")),
            accessControl: CredentialAccessController(store: CredentialAccessPolicyStore(
                fileURL: directory.appendingPathComponent("rules.json"), signer: FakeAccessRulesSigner())),
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(
                directory: directory.appendingPathComponent("authority"), checkpointService: settingsName)),
            settings: settings
        )

        model.staleLogins.mark(original.metadata.candidates)
        await model.loadStatus()
        await model.importCredentials(token: UUID())

        #expect(model.staleLogins.credentialIDs == Set(original.items.map(\.id)))
        #expect(try await store.loadCurrent() == original)
        #expect(model.status == original.safeStatus)
        #expect(model.notice?.kind == .error)
        #expect(model.notice?.text.contains("one-time import token") == true)
        #expect(model.notice?.text.contains("existing encrypted mirror was not changed") == true)
    }

    @Test("Import diagnostics contain error codes but not descriptions or user info")
    func safeDiagnostics() {
        let secret = "CANARY-CREDENTIAL-DATA"
        let error = NSError(
            domain: ASAuthorizationErrorDomain,
            code: ASAuthorizationError.failed.rawValue,
            userInfo: [NSLocalizedDescriptionKey: secret]
        )

        let failure = CredentialImportFailure(error: error, hadExistingMirror: true)

        #expect(failure.diagnostic.contains("/1004"))
        #expect(!failure.diagnostic.contains(secret))
        #expect(!failure.message.contains(secret))
    }

    private func generation() -> MirrorGeneration {
        let itemID = UUID()
        return MirrorGeneration(
            id: UUID(),
            previousGenerationID: nil,
            createdAt: Date(timeIntervalSince1970: 2_000),
            sourceExportedAt: Date(timeIntervalSince1970: 1_900),
            scope: .full,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: [
                MirrorItem(
                    id: itemID,
                    sourceIdentity: MirrorSourceIdentity(
                        exporterIdentifier: "com.apple.Passwords",
                        accountID: Data("account".utf8),
                        itemID: Data("item".utf8)
                    ),
                    title: "Existing",
                    origins: ["https://existing.example/login"],
                    credentials: [.password(userName: "account", password: "OLD-SECRET")]
                ),
                MirrorItem(id: UUID(), sourceIdentity: MirrorSourceIdentity(
                    exporterIdentifier: "com.apple.Passwords", accountID: Data("account".utf8),
                    itemID: Data("another-item".utf8)), title: "Unrelated login",
                    origins: ["https://other.example"],
                    credentials: [.password(userName: "someone-else", password: "UNRELATED-SYNTHETIC-PASSWORD")])
            ],
            skippedCredentialCount: 0
        )
    }
}

private struct SyntheticRefreshImporter: CredentialImporting {
    func importCredentials(token: UUID) async throws -> ASExportedCredentialData {
        let item = ASImportableItem(id: Data("item".utf8), created: Date(timeIntervalSince1970: 100),
            lastModified: Date(timeIntervalSince1970: 200),
            title: "Existing", scope: ASImportableCredentialScope(urls: [URL(string: "https://existing.example/login")!]),
            credentials: [.basicAuthentication(ASImportableCredential.BasicAuthentication(
                userName: ASImportableEditableField(id: nil, fieldType: .string, value: "account"),
                password: ASImportableEditableField(id: nil, fieldType: .concealedString,
                    value: "NEW-SYNTHETIC-PASSWORD")))])
        return ASExportedCredentialData(accounts: [ASImportableAccount(id: Data("account".utf8),
            userName: "", email: "", collections: [], items: [item])], formatVersion: .v1,
            exporterRelyingPartyIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords", timestamp: Date())
    }
}

private struct RejectedTokenImporter: CredentialImporting {
    func importCredentials(token: UUID) async throws -> ASExportedCredentialData {
        throw NSError(
            domain: ASAuthorizationErrorDomain,
            code: ASAuthorizationError.failed.rawValue
        )
    }
}
