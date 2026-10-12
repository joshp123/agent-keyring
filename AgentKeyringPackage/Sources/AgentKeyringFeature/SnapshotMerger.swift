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
        let previousByNaturalKey = Dictionary(grouping: previousItems, by: naturalKey)
        let incomingByNaturalKey = Dictionary(grouping: importBatch.items, by: naturalKey)

        var matchedPreviousIDs = Set<UUID>()
        var mergedItems: [MirrorItem] = []

        for importedItem in importBatch.items {
            let previousItem = try match(
                importedItem,
                previousBySource: previousBySource,
                previousByNaturalKey: previousByNaturalKey,
                incomingByNaturalKey: incomingByNaturalKey,
                alreadyMatched: matchedPreviousIDs
            )

            guard let previousItem else {
                let newItem = importedItem.replacingID(idFactory())
                mergedItems.append(newItem)
                continue
            }

            matchedPreviousIDs.insert(previousItem.id)
            let updatedItem = importedItem.replacingID(previousItem.id)
            mergedItems.append(updatedItem)
        }

        return MirrorGeneration(
            id: idFactory(),
            previousGenerationID: previous?.id,
            createdAt: now(),
            sourceExportedAt: importBatch.exportedAt,
            scope: importBatch.scope,
            exporterIdentifier: importBatch.exporterIdentifier,
            exporterDisplayName: importBatch.exporterDisplayName,
            items: mergedItems.sorted { $0.id.uuidString < $1.id.uuidString },
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

    private func match(
        _ importedItem: MirrorItem,
        previousBySource: [MirrorSourceIdentity: MirrorItem],
        previousByNaturalKey: [String?: [MirrorItem]],
        incomingByNaturalKey: [String?: [MirrorItem]],
        alreadyMatched: Set<UUID>
    ) throws -> MirrorItem? {
        if let directMatch = previousBySource[importedItem.sourceIdentity] {
            guard !alreadyMatched.contains(directMatch.id) else {
                throw MirrorError.ambiguousMatch
            }
            return directMatch
        }

        guard
            let key = naturalKey(importedItem),
            let previousMatches = previousByNaturalKey[key],
            let incomingMatches = incomingByNaturalKey[key]
        else {
            return nil
        }
        guard previousMatches.count == 1, incomingMatches.count == 1 else {
            return nil
        }
        guard let fallbackMatch = previousMatches.first, !alreadyMatched.contains(fallbackMatch.id)
        else {
            return nil
        }
        return fallbackMatch
    }

    private func naturalKey(_ item: MirrorItem) -> String? {
        let canonicalOrigins = item.origins
            .compactMap { URL(string: $0) }
            .compactMap { url -> String? in
                guard let host = url.host?.lowercased() else { return nil }
                let scheme = url.scheme?.lowercased() ?? "https"
                let port = url.port ?? (scheme == "https" ? 443 : 80)
                return "\(scheme)://\(host):\(port)"
            }
            .sorted()

        let userName = item.credentials.lazy.compactMap { credential -> String? in
            switch credential {
            case let .password(userName, _):
                userName
            case let .totp(_, _, _, userName, _, _):
                userName
            }
        }.first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        guard let origin = canonicalOrigins.first, let userName, !userName.isEmpty else {
            return nil
        }
        return "\(origin)|\(userName)"
    }

}
