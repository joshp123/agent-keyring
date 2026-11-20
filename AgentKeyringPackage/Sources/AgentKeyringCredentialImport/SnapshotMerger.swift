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

    /// The Passwords app gives every item new ids on each export, so an item
    /// is matched by its source identity first, then by what it is: the same
    /// sites, account names and title. Matching is one to one, so two entries
    /// that look the same in Passwords stay two. A match keeps the earlier
    /// entry's id, and with it his rule. When two earlier entries fit, the one
    /// in `keep` (his rule set on it) wins. A full copy replaces the list,
    /// except the test password; any other copy keeps what it left out.
    public func merge(
        previous: MirrorGeneration?,
        importBatch: MirrorImportBatch,
        keep: Set<UUID> = []
    ) throws -> MirrorGeneration {
        let previousItems = previous?.items ?? []
        try validateUniqueSourceIdentities(previousItems)
        try validateUniqueSourceIdentities(importBatch.items)

        var unmatched = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.sourceIdentity, $0) })
        var matches: [MirrorSourceIdentity: MirrorItem] = [:]
        for importedItem in importBatch.items {
            if let previousItem = unmatched.removeValue(forKey: importedItem.sourceIdentity) {
                matches[importedItem.sourceIdentity] = previousItem
            }
        }
        var byFingerprint: [Fingerprint: [MirrorItem]] = [:]
        for item in unmatched.values.sorted(by: { (keep.contains($0.id) ? 0 : 1, $0.id.uuidString) < (keep.contains($1.id) ? 0 : 1, $1.id.uuidString) }) {
            byFingerprint[fingerprint(item), default: []].append(item)
        }
        for importedItem in importBatch.items where matches[importedItem.sourceIdentity] == nil {
            guard var candidates = byFingerprint[fingerprint(importedItem)], !candidates.isEmpty else { continue }
            let index = candidates.firstIndex { $0.createdAt == importedItem.createdAt } ?? 0
            let previousItem = candidates.remove(at: index)
            byFingerprint[fingerprint(importedItem)] = candidates
            unmatched.removeValue(forKey: previousItem.sourceIdentity)
            matches[importedItem.sourceIdentity] = previousItem
        }

        var mergedItems = importBatch.items.map { importedItem in
            guard let previousItem = matches[importedItem.sourceIdentity] else { return importedItem.replacingID(idFactory()) }
            let sameAuthorization = accountNames(in: importedItem) == accountNames(in: previousItem)
                && Set(importedItem.origins) == Set(previousItem.origins)
            return importedItem.replacingID(sameAuthorization ? previousItem.id : idFactory())
        }
        let unmatchedPrevious = Array(unmatched.values)
        mergedItems += importBatch.scope == .full ? unmatchedPrevious.filter(\.isTestPassword) : unmatchedPrevious

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

    private struct Fingerprint: Hashable {
        let origins: Set<String>
        let accounts: Set<CredentialAccount>
        let title: String
    }

    private func fingerprint(_ item: MirrorItem) -> Fingerprint {
        Fingerprint(origins: Set(item.origins), accounts: accountNames(in: item), title: item.title)
    }

    private func validateUniqueSourceIdentities(_ items: [MirrorItem]) throws {
        var identities = Set<MirrorSourceIdentity>()
        for item in items where !identities.insert(item.sourceIdentity).inserted {
            throw MirrorError.duplicateSourceIdentity
        }
    }

    private enum CredentialAccount: Hashable {
        case password(String?)
        case totp(String?)
    }

    private func accountNames(in item: MirrorItem) -> Set<CredentialAccount> {
        Set(item.credentials.map { credential in
            switch credential {
            case let .password(userName, _):
                CredentialAccount.password(userName)
            case let .totp(_, _, _, userName, _, _):
                CredentialAccount.totp(userName)
            }
        })
    }

}
