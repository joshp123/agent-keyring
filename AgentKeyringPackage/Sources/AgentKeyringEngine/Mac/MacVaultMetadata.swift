#if os(macOS)
import Foundation

extension StoredVaultSnapshot {
    var metadata: MacVaultMetadata {
        MacVaultMetadata(safeStatus: safeStatus, candidates: items.map(\.candidate))
    }

    public var safeStatus: ImportedVaultStatus {
        ImportedVaultStatus(
            snapshotID: id,
            importedAt: createdAt,
            sourceExportedAt: sourceExportedAt,
            scope: scope,
            credentialItemCount: items.count,
            skippedCredentialCount: skippedCredentialCount,
            skippedCredentialSummary: skippedCredentialSummary,
            sampleOnly: items.allSatisfy(\.isTestPassword),
            testPasswordID: items.first(where: \.isTestPassword)?.id
        )
    }
}

public struct MacVaultMetadata: Equatable, Sendable {
    public let safeStatus: ImportedVaultStatus
    public let candidates: [CredentialCandidate]

    public var id: UUID { safeStatus.snapshotID }
    public var createdAt: Date { safeStatus.importedAt }

    public init(safeStatus: ImportedVaultStatus, candidates: [CredentialCandidate]) {
        self.safeStatus = safeStatus
        self.candidates = candidates
    }
}
#endif
