import AgentKeyringCredentialImport
import Foundation

/// The on-disk index contains no passwords or code seeds. Ciphertexts are separate files.
public struct PhoneVaultItemMetadata: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceIdentity: MirrorSourceIdentity
    public let title: String
    public let sites: [String]
    public let account: String?
    public let hasOneTimeCode: Bool

    init(_ item: MirrorItem) {
        id = item.id
        sourceIdentity = item.sourceIdentity
        title = item.title
        sites = item.origins
        account = item.credentials.lazy.compactMap { credential in
            switch credential {
            case let .password(userName, _): userName
            case let .totp(_, _, _, userName, _, _): userName
            }
        }.first
        hasOneTimeCode = item.credentials.contains { if case .totp = $0 { true } else { false } }
    }

    // Only used to feed the shared additive matcher. Never returned as a login.
    var matchingItem: MirrorItem {
        MirrorItem(id: id, sourceIdentity: sourceIdentity, title: title, origins: sites,
                   credentials: [.password(userName: account, password: "")])
    }
}

struct PhoneVaultRecord: Codable, Sendable {
    let metadata: PhoneVaultItemMetadata
    let ciphertextID: UUID
}

struct PhoneVaultManifest: Codable, Sendable {
    let version: Int
    let generationID: UUID
    let importedAt: Date
    let sourceExportedAt: Date
    let vaultPublicKey: Data
    let records: [PhoneVaultRecord]

    var matchingGeneration: MirrorGeneration {
        MirrorGeneration(id: generationID, previousGenerationID: nil, createdAt: importedAt,
                         sourceExportedAt: sourceExportedAt, scope: .unknown,
                         exporterIdentifier: "", exporterDisplayName: "",
                         items: records.map(\.metadata.matchingItem), skippedCredentialCount: 0)
    }
}

public struct PhoneVaultStatus: Sendable {
    public let loginCount: Int
    public let importedAt: Date
}

public enum PhoneVaultFailure: Error {
    case unsupportedVersion
    case vaultKeyChanged
    case loginUnavailable
    case itemMetadataChanged
    case invalidOwnerIndex
    case staleOwnerIndex
    case changedOwnerIndexAtSameRevision
}
