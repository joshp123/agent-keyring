import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Encrypted snapshot storage")
struct EncryptedSnapshotStoreTests {
    @Test("A successful save prunes previous encrypted generations")
    func immutableGenerations() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedSnapshotStore(
            directoryURL: directory,
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x2A, count: 32))
        )
        let first = generation(password: "first-password")
        let second = generation(password: "second-password", previousID: first.id)

        try await store.save(first)
        try await store.save(second)

        #expect(try await store.loadCurrent() == second)
        let oldURL = await store.generationFileURL(for: first.id)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try await store.loadCurrent(metadataOnly: true) == second.metadataOnly)
    }

    @Test("The encrypted file and safe status do not expose credential canaries")
    func secretsDoNotLeak() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedSnapshotStore(
            directoryURL: directory,
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x4B, count: 32))
        )
        let snapshot = generation(password: "CANARY-PASSWORD-4791")

        try await store.save(snapshot)
        let encryptedURL = await store.generationFileURL(for: snapshot.id)
        let encryptedBytes = try Data(contentsOf: encryptedURL)
        let encryptedText = String(decoding: encryptedBytes, as: UTF8.self)
        let statusText = String(
            decoding: try JSONEncoder().encode(snapshot.safeStatus),
            as: UTF8.self
        )

        #expect(!encryptedText.contains("CANARY-PASSWORD-4791"))
        #expect(!encryptedText.contains("canary.example"))
        #expect(!encryptedText.contains("canary-user"))
        #expect(!statusText.contains("CANARY-PASSWORD-4791"))
        #expect(!statusText.contains("canary.example"))
        #expect(!statusText.contains("canary-user"))
    }

    @Test("Discovery loads metadata with the secret payload unavailable")
    func metadataDoesNotReadSecrets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedSnapshotStore(directoryURL: directory,
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x2A, count: 32)))
        let snapshot = generation(password: "SECRET-CANARY")
        try await store.save(snapshot)
        let payloadURL = await store.generationFileURL(for: snapshot.id)
        try Data("unreadable secret payload".utf8).write(to: payloadURL)
        let metadata = try #require(try await store.loadCurrent(metadataOnly: true))
        #expect(metadata.safeStatus == snapshot.safeStatus)
        #expect(try CredentialResolver().candidates(in: metadata, targetURL: "https://canary.example").first?.username == "canary-user")
        #expect(!String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self).contains("SECRET-CANARY"))
    }

    @Test("A corrupt metadata index is an error without a snapshot fallback")
    func corruptMetadataDoesNotRebuild() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedSnapshotStore(directoryURL: directory,
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x2A, count: 32)))
        let snapshot = generation(password: "SECRET-CANARY")
        try await store.save(snapshot)
        let payloadURL = await store.generationFileURL(for: snapshot.id)
        let metadataURL = payloadURL.deletingPathExtension().appendingPathExtension("metadata")
        let corruptMetadata = Data("corrupt metadata".utf8)
        try corruptMetadata.write(to: metadataURL)
        await #expect(throws: (any Error).self) {
            try await store.loadCurrent(metadataOnly: true)
        }
        #expect(try Data(contentsOf: metadataURL) == corruptMetadata)
        #expect(try await store.loadCurrent() == snapshot)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKeyringTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func generation(password: String, previousID: UUID? = nil) -> MirrorGeneration {
        let itemID = UUID()
        return MirrorGeneration(
            id: UUID(),
            previousGenerationID: previousID,
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
                    title: "Canary",
                    origins: ["https://canary.example/login"],
                    credentials: [
                        .password(userName: "canary-user", password: password)
                    ]
                )
            ],
            delta: MirrorDelta(addedItemIDs: [itemID]),
            skippedCredentialCount: 0
        )
    }
}
