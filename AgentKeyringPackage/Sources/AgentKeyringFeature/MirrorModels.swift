import Foundation

public enum MirrorImportScope: String, Codable, Equatable, Sendable {
    case full
    case selected
}

public struct MirrorSourceIdentity: Codable, Equatable, Hashable, Sendable {
    public let exporterIdentifier: String
    public let accountID: Data
    public let itemID: Data

    public init(exporterIdentifier: String, accountID: Data, itemID: Data) {
        self.exporterIdentifier = exporterIdentifier
        self.accountID = accountID
        self.itemID = itemID
    }
}

public enum MirrorTOTPAlgorithm: String, Codable, Equatable, Sendable {
    case sha1
    case sha256
    case sha512
}

public enum MirrorCredential: Codable, Equatable, Sendable {
    case password(userName: String?, password: String)
    case totp(
        secret: Data,
        period: UInt16,
        digits: UInt16,
        userName: String?,
        algorithm: MirrorTOTPAlgorithm,
        issuer: String?
    )
}

public struct MirrorItem: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceIdentity: MirrorSourceIdentity
    public let createdAt: Date?
    public let lastModifiedAt: Date?
    public let title: String
    public let subtitle: String?
    public let isFavorite: Bool
    public let origins: [String]
    public let credentials: [MirrorCredential]

    public init(
        id: UUID,
        sourceIdentity: MirrorSourceIdentity,
        createdAt: Date? = nil,
        lastModifiedAt: Date? = nil,
        title: String,
        subtitle: String? = nil,
        isFavorite: Bool = false,
        origins: [String],
        credentials: [MirrorCredential]
    ) {
        self.id = id
        self.sourceIdentity = sourceIdentity
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
        self.title = title
        self.subtitle = subtitle
        self.isFavorite = isFavorite
        self.origins = origins
        self.credentials = credentials
    }

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

    func replacingID(_ id: UUID) -> MirrorItem {
        MirrorItem(
            id: id,
            sourceIdentity: sourceIdentity,
            createdAt: createdAt,
            lastModifiedAt: lastModifiedAt,
            title: title,
            subtitle: subtitle,
            isFavorite: isFavorite,
            origins: origins,
            credentials: credentials
        )
    }
}

public struct MirrorImportBatch: Equatable, Sendable {
    public let scope: MirrorImportScope
    public let exportedAt: Date
    public let exporterIdentifier: String
    public let exporterDisplayName: String
    public let items: [MirrorItem]
    public let skippedCredentialCount: Int
    public let skippedCredentialSummary: MirrorSkippedCredentialSummary?

    public init(
        scope: MirrorImportScope,
        exportedAt: Date,
        exporterIdentifier: String,
        exporterDisplayName: String,
        items: [MirrorItem],
        skippedCredentialCount: Int,
        skippedCredentialSummary: MirrorSkippedCredentialSummary? = nil
    ) {
        self.scope = scope
        self.exportedAt = exportedAt
        self.exporterIdentifier = exporterIdentifier
        self.exporterDisplayName = exporterDisplayName
        self.items = items
        self.skippedCredentialCount = skippedCredentialCount
        self.skippedCredentialSummary = skippedCredentialSummary
    }
}

public struct MirrorSkippedCredentialSummary: Codable, Equatable, Sendable {
    public let passkeyCount: Int
    public let missingPasswordCount: Int
    public let otherCount: Int

    public init(
        passkeyCount: Int = 0,
        missingPasswordCount: Int = 0,
        otherCount: Int = 0
    ) {
        self.passkeyCount = passkeyCount
        self.missingPasswordCount = missingPasswordCount
        self.otherCount = otherCount
    }

    public var totalCount: Int {
        passkeyCount + missingPasswordCount + otherCount
    }
}

public struct MirrorItemChange: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let credentialsChanged: Bool
    public let metadataChanged: Bool

    public init(itemID: UUID, credentialsChanged: Bool, metadataChanged: Bool) {
        self.itemID = itemID
        self.credentialsChanged = credentialsChanged
        self.metadataChanged = metadataChanged
    }
}

public struct MirrorDelta: Codable, Equatable, Sendable {
    public let addedItemIDs: [UUID]
    public let changedItems: [MirrorItemChange]
    public let removedItemIDs: [UUID]

    public init(
        addedItemIDs: [UUID] = [],
        changedItems: [MirrorItemChange] = [],
        removedItemIDs: [UUID] = []
    ) {
        self.addedItemIDs = addedItemIDs
        self.changedItems = changedItems
        self.removedItemIDs = removedItemIDs
    }
}

public struct MirrorGeneration: Codable, Equatable, Sendable {
    public let id: UUID
    public let previousGenerationID: UUID?
    public let createdAt: Date
    public let sourceExportedAt: Date
    public let scope: MirrorImportScope
    public let exporterIdentifier: String
    public let exporterDisplayName: String
    public let items: [MirrorItem]
    public let delta: MirrorDelta
    public let skippedCredentialCount: Int
    public let skippedCredentialSummary: MirrorSkippedCredentialSummary?

    public init(
        id: UUID,
        previousGenerationID: UUID?,
        createdAt: Date,
        sourceExportedAt: Date,
        scope: MirrorImportScope,
        exporterIdentifier: String,
        exporterDisplayName: String,
        items: [MirrorItem],
        delta: MirrorDelta,
        skippedCredentialCount: Int,
        skippedCredentialSummary: MirrorSkippedCredentialSummary? = nil
    ) {
        self.id = id
        self.previousGenerationID = previousGenerationID
        self.createdAt = createdAt
        self.sourceExportedAt = sourceExportedAt
        self.scope = scope
        self.exporterIdentifier = exporterIdentifier
        self.exporterDisplayName = exporterDisplayName
        self.items = items
        self.delta = delta
        self.skippedCredentialCount = skippedCredentialCount
        self.skippedCredentialSummary = skippedCredentialSummary
    }

    public var safeStatus: SafeMirrorStatus {
        SafeMirrorStatus(
            generationID: id,
            importedAt: createdAt,
            sourceExportedAt: sourceExportedAt,
            scope: scope,
            credentialItemCount: items.count,
            addedCount: delta.addedItemIDs.count,
            changedCount: delta.changedItems.count,
            removedCount: delta.removedItemIDs.count,
            skippedCredentialCount: skippedCredentialCount,
            skippedCredentialSummary: skippedCredentialSummary
        )
    }
}

public struct SafeMirrorStatus: Codable, Equatable, Sendable {
    public let generationID: UUID
    public let importedAt: Date
    public let sourceExportedAt: Date
    public let scope: MirrorImportScope
    public let credentialItemCount: Int
    public let addedCount: Int
    public let changedCount: Int
    public let removedCount: Int
    public let skippedCredentialCount: Int
    public let skippedCredentialSummary: MirrorSkippedCredentialSummary?

    public init(
        generationID: UUID,
        importedAt: Date,
        sourceExportedAt: Date,
        scope: MirrorImportScope,
        credentialItemCount: Int,
        addedCount: Int,
        changedCount: Int,
        removedCount: Int,
        skippedCredentialCount: Int,
        skippedCredentialSummary: MirrorSkippedCredentialSummary? = nil
    ) {
        self.generationID = generationID
        self.importedAt = importedAt
        self.sourceExportedAt = sourceExportedAt
        self.scope = scope
        self.credentialItemCount = credentialItemCount
        self.addedCount = addedCount
        self.changedCount = changedCount
        self.removedCount = removedCount
        self.skippedCredentialCount = skippedCredentialCount
        self.skippedCredentialSummary = skippedCredentialSummary
    }
}

public enum MirrorError: Error, Equatable, LocalizedError {
    case ambiguousMatch
    case duplicateSourceIdentity
    case invalidCurrentPointer
    case missingEncryptedPayload

    public var errorDescription: String? {
        switch self {
        case .ambiguousMatch:
            "The import contains credentials that cannot be matched safely."
        case .duplicateSourceIdentity:
            "The import contains duplicate credential identifiers."
        case .invalidCurrentPointer:
            "The mirror's current-generation pointer is invalid."
        case .missingEncryptedPayload:
            "The encrypted snapshot payload is unavailable."
        }
    }
}
