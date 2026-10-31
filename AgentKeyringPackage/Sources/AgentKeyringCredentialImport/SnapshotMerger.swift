import Foundation

public struct SnapshotMerger: Sendable {
    private let idFactory: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        idFactory: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.idFactory = idFactory
        self.now = now
    }

    public func merge(
        previous: MirrorGeneration?,
        importBatch: MirrorImportBatch
    ) throws -> MirrorGeneration {
        let previousItems = previous?.items ?? []
        try validateUniqueSourceIdentities(previousItems)
        try validateUniqueSourceIdentities(importBatch.items)

        let previousBySource = Dictionary(
            uniqueKeysWithValues: previousItems.map {
                ($0.sourceIdentity, $0)
            })
        var matchedPreviousIDs = Set<UUID>()
        var mergedItems: [MirrorItem] = []

        for importedItem in importBatch.items {
            guard let previousItem = previousBySource[importedItem.sourceIdentity] else {
                let newItem = importedItem.replacingID(idFactory())
                mergedItems.append(newItem)
                continue
            }

            matchedPreviousIDs.insert(previousItem.id)
            let sameAuthorization = accountNames(in: importedItem) == accountNames(in: previousItem)
                && Set(importedItem.origins) == Set(previousItem.origins)
            let updatedItem = importedItem.replacingID(sameAuthorization ? previousItem.id : idFactory())
            mergedItems.append(updatedItem)
        }

        let unmatchedPrevious = previousItems.filter { !matchedPreviousIDs.contains($0.id) }
        mergedItems.append(contentsOf: unmatchedPrevious)

        return MirrorGeneration(
            id: idFactory(),
            previousGenerationID: previous?.id,
            createdAt: now(),
            sourceExportedAt: importBatch.exportedAt,
            scope: importBatch.scope,
            exporterIdentifier: importBatch.exporterIdentifier,
            exporterDisplayName: importBatch.exporterDisplayName,
            items: mergedItems.sorted { $0.id.uuidString < $1.id.uuidString },
            missingItemIDs: unmatchedPrevious.map(\.id).sorted { $0.uuidString < $1.uuidString },
            skippedCredentialCount: importBatch.skippedCredentialCount,
            skippedCredentialSummary: importBatch.skippedCredentialSummary
        )
    }

    private func validateUniqueSourceIdentities(_ items: [MirrorItem]) throws {
        var identities = Set<MirrorSourceIdentity>()
        for item in items where !identities.insert(item.sourceIdentity).inserted {
            throw MirrorError.duplicateSourceIdentity
        }
    }

    private func accountNames(in item: MirrorItem) -> Set<String> {
        Set(item.credentials.compactMap { credential -> String? in
            switch credential {
            case let .password(userName, _):
                userName
            case let .totp(_, _, _, userName, _, _):
                userName
            }
        })
    }

}
