import AgentKeyringProtocol
import Foundation

public enum LoginImportScope: String, Equatable, Sendable {
    case full
    case selected
    case unknown
}

public struct LoginSourceIdentity: Equatable, Hashable, Sendable {
    public let exporterIdentifier: String
    public let accountID: Data
    public let itemID: Data

    public init(exporterIdentifier: String, accountID: Data, itemID: Data) {
        self.exporterIdentifier = exporterIdentifier
        self.accountID = accountID
        self.itemID = itemID
    }
}

public enum OneTimeCodeAlgorithm: String, Equatable, Sendable {
    case sha1
    case sha256
    case sha512
}

public enum ImportedLoginSecret: Equatable, Sendable {
    case password(userName: String?, password: String)
    case totp(
        secret: Data,
        period: UInt16,
        digits: UInt16,
        userName: String?,
        algorithm: OneTimeCodeAlgorithm,
        issuer: String?
    )
}

public struct StoredVaultLogin: Equatable, Sendable {
    /// `LoginIdentity.id(for:)` once merged; random as the mapper reads it.
    public internal(set) var id: UUID
    public let sourceIdentity: LoginSourceIdentity
    public let createdAt: Date?
    public let lastModifiedAt: Date?
    public let title: String
    public let subtitle: String?
    public let isFavorite: Bool
    public let origins: [String]
    public let credentials: [ImportedLoginSecret]
    /// Each device's latest import of the secret.
    public internal(set) var imports: [LoginSecretRevisionStamp]?
    /// Every import of the secret up to this one (`LoginSecretRevisionStamp.version`) was
    /// deleted when the login was Blocked, on every device.
    public internal(set) var secretsDeletedAt: UInt64?

    public init(
        id: UUID,
        sourceIdentity: LoginSourceIdentity,
        createdAt: Date? = nil,
        lastModifiedAt: Date? = nil,
        title: String,
        subtitle: String? = nil,
        isFavorite: Bool = false,
        origins: [String],
        credentials: [ImportedLoginSecret],
        imports: [LoginSecretRevisionStamp]? = nil,
        secretsDeletedAt: UInt64? = nil
    ) {
        self.imports = imports
        self.secretsDeletedAt = secretsDeletedAt
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

}

extension StoredVaultLogin {
    /// The account name agents and the screens see: the one password's, else the one code's.
    public var accountName: String? {
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

/// One import of a login's secret: its sealed copies all carry `version`.
public struct LoginSecretRevisionStamp: Hashable, Sendable {
    /// The login's `lastModifiedAt` in the export it came from.
    public let revision: Date?
    /// When it was imported, in Unix nanoseconds (`SealedLogin.version`).
    public let version: UInt64
    /// The device that imported it (`Device.key_id`).
    public let actor: String
    /// When Passwords made the export it came from.
    public let exportedAt: Date?

    public init(revision: Date?, version: UInt64, actor: String, exportedAt: Date? = nil) {
        self.revision = revision
        self.version = version
        self.actor = actor
        self.exportedAt = exportedAt
    }

    /// Newer revision first, then newer import: an older export imported late never displaces a newer one.
    func isNewer(than other: LoginSecretRevisionStamp) -> Bool {
        (revision ?? .distantPast, version, actor) > (other.revision ?? .distantPast, other.version, other.actor)
    }
}

public struct LoginImportBatch: Equatable, Sendable {
    public let scope: LoginImportScope
    public let exportedAt: Date
    public let exporterIdentifier: String
    public let exporterDisplayName: String
    public let items: [StoredVaultLogin]
    public let skippedCredentialCount: Int
    public let skippedCredentialSummary: SkippedLoginImportSummary?

    public init(
        scope: LoginImportScope,
        exportedAt: Date,
        exporterIdentifier: String,
        exporterDisplayName: String,
        items: [StoredVaultLogin],
        skippedCredentialCount: Int,
        skippedCredentialSummary: SkippedLoginImportSummary? = nil
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

public struct SkippedLoginImportSummary: Equatable, Sendable {
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

public struct StoredVaultSnapshot: Equatable, Sendable {
    public let id: UUID
    public let previousSnapshotID: UUID?
    public let createdAt: Date
    public let sourceExportedAt: Date
    public let scope: LoginImportScope
    public let exporterIdentifier: String
    public let exporterDisplayName: String
    public internal(set) var items: [StoredVaultLogin]
    public let missingItemIDs: [UUID]?
    public let skippedCredentialCount: Int
    public let skippedCredentialSummary: SkippedLoginImportSummary?
    /// Logins gone from Passwords, with the export that found them gone, so
    /// an older copy of the vault from another device does not bring them back.
    public internal(set) var deleted: [UUID: Date]?

    public init(
        id: UUID,
        previousSnapshotID: UUID?,
        createdAt: Date,
        sourceExportedAt: Date,
        scope: LoginImportScope,
        exporterIdentifier: String,
        exporterDisplayName: String,
        items: [StoredVaultLogin],
        missingItemIDs: [UUID]? = nil,
        skippedCredentialCount: Int,
        skippedCredentialSummary: SkippedLoginImportSummary? = nil,
        deleted: [UUID: Date]? = nil
    ) {
        self.deleted = deleted
        self.id = id
        self.previousSnapshotID = previousSnapshotID
        self.createdAt = createdAt
        self.sourceExportedAt = sourceExportedAt
        self.scope = scope
        self.exporterIdentifier = exporterIdentifier
        self.exporterDisplayName = exporterDisplayName
        self.items = items
        self.missingItemIDs = missingItemIDs
        self.skippedCredentialCount = skippedCredentialCount
        self.skippedCredentialSummary = skippedCredentialSummary
    }

}

public struct ImportedVaultStatus: Equatable, Sendable {
    public let snapshotID: UUID
    public let importedAt: Date
    public let sourceExportedAt: Date
    public let scope: LoginImportScope
    public let credentialItemCount: Int
    public let skippedCredentialCount: Int
    public let skippedCredentialSummary: SkippedLoginImportSummary?
    /// The only password is the test password (nil in a status saved before there was one).
    public let sampleOnly: Bool?
    /// The test password's id, for the "Test password" tag in Passwords (nil in a status saved before this).
    public let testPasswordID: UUID?

    public init(
        snapshotID: UUID,
        importedAt: Date,
        sourceExportedAt: Date,
        scope: LoginImportScope,
        credentialItemCount: Int,
        skippedCredentialCount: Int,
        skippedCredentialSummary: SkippedLoginImportSummary? = nil,
        sampleOnly: Bool? = nil,
        testPasswordID: UUID? = nil
    ) {
        self.testPasswordID = testPasswordID
        self.snapshotID = snapshotID
        self.importedAt = importedAt
        self.sourceExportedAt = sourceExportedAt
        self.scope = scope
        self.credentialItemCount = credentialItemCount
        self.skippedCredentialCount = skippedCredentialCount
        self.skippedCredentialSummary = skippedCredentialSummary
        self.sampleOnly = sampleOnly
    }
}

enum VaultStorageError: Error, Equatable, LocalizedError {
    case ambiguousMatch
    case duplicateSourceIdentity
    case invalidCurrentPointer
    case missingEncryptedPayload

    var errorDescription: String? {
        switch self {
        case .ambiguousMatch:
            "The import contains credentials that cannot be matched safely."
        case .duplicateSourceIdentity:
            "The import contains duplicate credential identifiers."
        case .invalidCurrentPointer:
            "The vault's current-snapshot pointer is invalid."
        case .missingEncryptedPayload:
            "The encrypted snapshot payload is unavailable."
        }
    }
}

extension StoredVaultLogin {
    /// The test password Agent Keyring always keeps, beside his own: for
    /// practice, and for an agent to try the whole route with a secret that
    /// does not matter. An ordinary Ask password, in the list and the
    /// catalogue like any other.
    static let testPasswordSource = "agent-keyring.sample"
    public static var testPassword: StoredVaultLogin {
        StoredVaultLogin(id: UUID(), sourceIdentity: LoginSourceIdentity(exporterIdentifier: testPasswordSource, accountID: Data("sample".utf8),
            itemID: Data("example.com".utf8)), title: "example.com", origins: ["https://example.com"],
            credentials: [.password(userName: "you@example.com", password: "hello")])
    }
    public var isTestPassword: Bool { sourceIdentity.exporterIdentifier == Self.testPasswordSource }
}

extension StoredVaultSnapshot {
    public static let protobufMagic = Data("AKRGEN02".utf8)

    public func encodeProtobuf() throws -> Data {
        Self.protobufMagic + (try storedProto().serializedData())
    }

    public static func decodeProtobuf(_ data: Data) throws -> StoredVaultSnapshot {
        guard data.starts(with: protobufMagic) else { throw StoredVaultCodecError.invalidMagic }
        let proto = try Agentkeyring_V2_StoredVaultSnapshot(serializedBytes: Data(data.dropFirst(protobufMagic.count)))
        return try StoredVaultSnapshot(storedProto: proto)
    }

    public init(storedProto proto: Agentkeyring_V2_StoredVaultSnapshot) throws {
        guard let id = UUID(uuidString: proto.id) else {
            throw StoredVaultCodecError.invalidUUID("StoredVaultSnapshot.id")
        }
        let previousID: UUID?
        if proto.hasPreviousSnapshotID {
            guard let parsed = UUID(uuidString: proto.previousSnapshotID) else {
                throw StoredVaultCodecError.invalidUUID("StoredVaultSnapshot.previousSnapshotID")
            }
            previousID = parsed
        } else {
            previousID = nil
        }
        let scope: LoginImportScope
        switch proto.scope {
        case .full: scope = .full
        case .selected: scope = .selected
        case .unknown: scope = .unknown
        default: throw StoredVaultCodecError.invalidEnum("StoredVaultSnapshot.scope")
        }
        let items = try proto.items.map(StoredVaultLogin.init(storedProto:))
        let missingItemIDs: [UUID]?
        if proto.hasMissingItemIds_p || !proto.missingItemIds.isEmpty {
            missingItemIDs = try proto.missingItemIds.map { raw in
                guard let parsed = UUID(uuidString: raw) else {
                    throw StoredVaultCodecError.invalidUUID("StoredVaultSnapshot.missingItemIDs")
                }
                return parsed
            }
        } else {
            missingItemIDs = nil
        }
        let summary: SkippedLoginImportSummary? = proto.hasSkippedCredentialSummary
            ? SkippedLoginImportSummary(
                passkeyCount: Int(proto.skippedCredentialSummary.passkeyCount),
                missingPasswordCount: Int(proto.skippedCredentialSummary.missingPasswordCount),
                otherCount: Int(proto.skippedCredentialSummary.otherCount)
            )
            : nil
        let deleted: [UUID: Date]?
        if proto.hasDeleted_p || !proto.deletedUnixSeconds.isEmpty {
            var map: [UUID: Date] = [:]
            for (rawID, seconds) in proto.deletedUnixSeconds {
                guard let parsed = UUID(uuidString: rawID) else {
                    throw StoredVaultCodecError.invalidUUID("StoredVaultSnapshot.deleted")
                }
                map[parsed] = Date(timeIntervalSince1970: seconds)
            }
            deleted = map
        } else {
            deleted = nil
        }
        self.init(
            id: id,
            previousSnapshotID: previousID,
            createdAt: Date(timeIntervalSince1970: proto.createdAtUnixSeconds),
            sourceExportedAt: Date(timeIntervalSince1970: proto.sourceExportedAtUnixSeconds),
            scope: scope,
            exporterIdentifier: proto.exporterIdentifier,
            exporterDisplayName: proto.exporterDisplayName,
            items: items,
            missingItemIDs: missingItemIDs,
            skippedCredentialCount: Int(proto.skippedCredentialCount),
            skippedCredentialSummary: summary,
            deleted: deleted
        )
    }

    public func storedProto() -> Agentkeyring_V2_StoredVaultSnapshot {
        var proto = Agentkeyring_V2_StoredVaultSnapshot()
        proto.id = id.uuidString
        if let previousSnapshotID { proto.previousSnapshotID = previousSnapshotID.uuidString }
        proto.createdAtUnixSeconds = createdAt.timeIntervalSince1970
        proto.sourceExportedAtUnixSeconds = sourceExportedAt.timeIntervalSince1970
        proto.scope = switch scope {
        case .full: .full
        case .selected: .selected
        case .unknown: .unknown
        }
        proto.exporterIdentifier = exporterIdentifier
        proto.exporterDisplayName = exporterDisplayName
        proto.items = items.map { $0.storedProto() }
        if let missingItemIDs {
            proto.missingItemIds = missingItemIDs.map(\.uuidString)
            proto.hasMissingItemIds_p = true
        }
        proto.skippedCredentialCount = Int32(skippedCredentialCount)
        if let skippedCredentialSummary {
            var summary = Agentkeyring_V2_StoredSkippedSummary()
            summary.passkeyCount = Int32(skippedCredentialSummary.passkeyCount)
            summary.missingPasswordCount = Int32(skippedCredentialSummary.missingPasswordCount)
            summary.otherCount = Int32(skippedCredentialSummary.otherCount)
            proto.skippedCredentialSummary = summary
        }
        if let deleted {
            proto.deletedUnixSeconds = Dictionary(
                uniqueKeysWithValues: deleted.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }
            )
            proto.hasDeleted_p = true
        }
        return proto
    }
}

extension StoredVaultLogin {
    public init(storedProto proto: Agentkeyring_V2_StoredVaultLogin) throws {
        guard let id = UUID(uuidString: proto.id) else {
            throw StoredVaultCodecError.invalidUUID("StoredVaultLogin.id")
        }
        guard proto.hasSourceIdentity else {
            throw StoredVaultCodecError.missingField("StoredVaultLogin.sourceIdentity")
        }
        let sourceIdentity = LoginSourceIdentity(
            exporterIdentifier: proto.sourceIdentity.exporterIdentifier,
            accountID: proto.sourceIdentity.accountID,
            itemID: proto.sourceIdentity.itemID
        )
        let credentials = try proto.credentials.map(ImportedLoginSecret.init(storedProto:))
        let imports: [LoginSecretRevisionStamp]? = (proto.hasImports_p || !proto.imports.isEmpty)
            ? proto.imports.map(LoginSecretRevisionStamp.init(storedProto:))
            : nil
        self.init(
            id: id,
            sourceIdentity: sourceIdentity,
            createdAt: proto.hasCreatedAtUnixSeconds ? Date(timeIntervalSince1970: proto.createdAtUnixSeconds) : nil,
            lastModifiedAt: proto.hasLastModifiedAtUnixSeconds ? Date(timeIntervalSince1970: proto.lastModifiedAtUnixSeconds) : nil,
            title: proto.title,
            subtitle: proto.hasSubtitle ? proto.subtitle : nil,
            isFavorite: proto.isFavorite,
            origins: proto.origins,
            credentials: credentials,
            imports: imports,
            secretsDeletedAt: proto.hasSecretsDeletedAt ? proto.secretsDeletedAt : nil
        )
    }

    public func storedProto() -> Agentkeyring_V2_StoredVaultLogin {
        var proto = Agentkeyring_V2_StoredVaultLogin()
        proto.id = id.uuidString
        var identity = Agentkeyring_V2_StoredSourceIdentity()
        identity.exporterIdentifier = sourceIdentity.exporterIdentifier
        identity.accountID = sourceIdentity.accountID
        identity.itemID = sourceIdentity.itemID
        proto.sourceIdentity = identity
        if let createdAt { proto.createdAtUnixSeconds = createdAt.timeIntervalSince1970 }
        if let lastModifiedAt { proto.lastModifiedAtUnixSeconds = lastModifiedAt.timeIntervalSince1970 }
        proto.title = title
        if let subtitle { proto.subtitle = subtitle }
        proto.isFavorite = isFavorite
        proto.origins = origins
        proto.credentials = credentials.map { $0.storedProto() }
        if let imports {
            proto.imports = imports.map { $0.storedProto() }
            proto.hasImports_p = true
        }
        if let secretsDeletedAt { proto.secretsDeletedAt = secretsDeletedAt }
        return proto
    }
}

extension ImportedLoginSecret {
    init(storedProto proto: Agentkeyring_V2_StoredCredential) throws {
        switch proto.kind {
        case let .password(pw):
            self = .password(userName: pw.hasUsername ? pw.username : nil, password: pw.password)
        case let .totp(totp):
            guard let period = UInt16(exactly: totp.period), let digits = UInt16(exactly: totp.digits) else {
                throw StoredVaultCodecError.invalidField("StoredCredential.totp")
            }
            let algorithm: OneTimeCodeAlgorithm
            switch totp.algorithm {
            case .sha1: algorithm = .sha1
            case .sha256: algorithm = .sha256
            case .sha512: algorithm = .sha512
            default: throw StoredVaultCodecError.invalidEnum("StoredCredential.totp.algorithm")
            }
            self = .totp(
                secret: totp.secret,
                period: period,
                digits: digits,
                userName: totp.hasUsername ? totp.username : nil,
                algorithm: algorithm,
                issuer: totp.hasIssuer ? totp.issuer : nil
            )
        case nil:
            throw StoredVaultCodecError.missingField("StoredCredential.kind")
        }
    }

    func storedProto() -> Agentkeyring_V2_StoredCredential {
        var proto = Agentkeyring_V2_StoredCredential()
        switch self {
        case let .password(userName, password):
            var pw = Agentkeyring_V2_StoredCredential.Password()
            if let userName { pw.username = userName }
            pw.password = password
            proto.password = pw
        case let .totp(secret, period, digits, userName, algorithm, issuer):
            var totp = Agentkeyring_V2_StoredCredential.TOTP()
            totp.secret = secret
            totp.period = UInt32(period)
            totp.digits = UInt32(digits)
            if let userName { totp.username = userName }
            totp.algorithm = switch algorithm {
            case .sha1: .sha1
            case .sha256: .sha256
            case .sha512: .sha512
            }
            if let issuer { totp.issuer = issuer }
            proto.totp = totp
        }
        return proto
    }
}

extension LoginSecretRevisionStamp {
    init(storedProto proto: Agentkeyring_V2_StoredSecretStamp) {
        self.init(
            revision: proto.hasRevisionUnixSeconds ? Date(timeIntervalSince1970: proto.revisionUnixSeconds) : nil,
            version: proto.version,
            actor: proto.actor,
            exportedAt: proto.hasExportedAtUnixSeconds ? Date(timeIntervalSince1970: proto.exportedAtUnixSeconds) : nil
        )
    }

    func storedProto() -> Agentkeyring_V2_StoredSecretStamp {
        var proto = Agentkeyring_V2_StoredSecretStamp()
        if let revision { proto.revisionUnixSeconds = revision.timeIntervalSince1970 }
        proto.version = version
        proto.actor = actor
        if let exportedAt { proto.exportedAtUnixSeconds = exportedAt.timeIntervalSince1970 }
        return proto
    }
}

enum StoredVaultCodecError: Error {
    case invalidMagic
    case invalidUUID(String)
    case invalidEnum(String)
    case invalidField(String)
    case missingField(String)
}
