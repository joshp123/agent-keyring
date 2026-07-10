import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Encrypted snapshot storage")
struct EncryptedSnapshotStoreTests {
    @Test("Generations round-trip and remain immutable")
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
        #expect(try await store.load(generationID: first.id) == first)
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
