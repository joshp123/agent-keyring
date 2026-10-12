import AuthenticationServices
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Credential import failures")
struct MirrorImportFailureTests {
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
            settings: settings
        )

        await model.loadStatus()
        await model.importCredentials(token: UUID())

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
                )
            ],
            skippedCredentialCount: 0
        )
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
