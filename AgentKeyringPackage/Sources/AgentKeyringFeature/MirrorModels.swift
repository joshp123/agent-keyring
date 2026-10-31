import Foundation

extension MirrorItem {
    var isExample: Bool { id == Self.exampleCredentialID }

    var accountName: String? {
        let passwordNames = credentials.compactMap { credential -> String? in
            guard case let .password(userName, _) = credential else { return nil }
            return userName
        }.filter { !$0.isEmpty }
        if passwordNames.count == 1 { return passwordNames[0] }
        let codeNames = credentials.compactMap { credential -> String? in
            guard case let .totp(_, _, _, userName, _, _) = credential else { return nil }
            return userName
        }.filter { !$0.isEmpty }
        return codeNames.count == 1 ? codeNames[0] : nil
    }
}

extension MirrorGeneration {
    var metadata: MirrorMetadata {
        MirrorMetadata(safeStatus: safeStatus, candidates: items.map {
            CredentialResolver().candidate(for: $0)
        })
    }

    public var safeStatus: SafeMirrorStatus {
        SafeMirrorStatus(
            generationID: id,
            importedAt: createdAt,
            sourceExportedAt: sourceExportedAt,
            scope: scope,
            credentialItemCount: items.filter { !$0.isExample }.count,
            skippedCredentialCount: skippedCredentialCount,
            skippedCredentialSummary: skippedCredentialSummary
        )
    }
}

public struct MirrorMetadata: Codable, Equatable, Sendable {
    public let safeStatus: SafeMirrorStatus
    public let candidates: [CredentialCandidate]

    public var id: UUID { safeStatus.generationID }
    public var createdAt: Date { safeStatus.importedAt }

    public init(safeStatus: SafeMirrorStatus, candidates: [CredentialCandidate]) {
        self.safeStatus = safeStatus
        self.candidates = candidates
    }
}
