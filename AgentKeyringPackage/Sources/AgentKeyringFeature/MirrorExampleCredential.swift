import Foundation

@available(macOS 26.0, *)
extension MirrorAppModel {
    func metadataIncludingExample(_ metadata: MirrorMetadata?) -> MirrorMetadata? {
        guard let example = generationIncludingExample(nil)?.metadata else { return metadata }
        guard let metadata else { return example }
        guard !metadata.candidates.contains(where: { $0.id == MirrorItem.exampleCredentialID }) else {
            return metadata
        }
        return MirrorMetadata(safeStatus: metadata.safeStatus,
            candidates: metadata.candidates + example.candidates)
    }

    func generationIncludingExample(_ generation: MirrorGeneration?) -> MirrorGeneration? {
        guard includeExampleCredential else { return generation }

        let item = MirrorItem(
            id: MirrorItem.exampleCredentialID,
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: "com.agentkeyring.example",
                accountID: Data("example@example.com".utf8),
                itemID: Data("example.com".utf8)
            ),
            title: "example.com",
            origins: ["https://example.com"],
            credentials: [
                .password(userName: "example@example.com", password: "example-password")
            ]
        )

        guard let generation else {
            return MirrorGeneration(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0)),
                previousGenerationID: nil,
                createdAt: Date(),
                sourceExportedAt: Date(),
                scope: .full,
                exporterIdentifier: "com.agentkeyring.example",
                exporterDisplayName: "Agent Keyring",
                items: [item],
                skippedCredentialCount: 0
            )
        }

        guard !generation.items.contains(where: { $0.id == item.id }) else {
            return generation
        }
        return MirrorGeneration(
            id: generation.id,
            previousGenerationID: generation.previousGenerationID,
            createdAt: generation.createdAt,
            sourceExportedAt: generation.sourceExportedAt,
            scope: generation.scope,
            exporterIdentifier: generation.exporterIdentifier,
            exporterDisplayName: generation.exporterDisplayName,
            items: generation.items + [item],
            skippedCredentialCount: generation.skippedCredentialCount,
            skippedCredentialSummary: generation.skippedCredentialSummary
        )
    }
}
