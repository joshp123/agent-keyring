// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// What the Mac keeps of the imported logins: the import with every secret
// removed (names, sites, accounts, and which fields each login has, so the next
// import keeps each login's ID), and the logins sealed to each key that may
// open them. Nothing here is readable without one of those keys.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

public actor LoginStore {
    private let directory: URL
    private var listURL: URL { directory.appending(path: "logins.json") }
    private var sealedURL: URL { directory.appending(path: "sealed.pb") }

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/logins")) {
        self.directory = directory
    }

    /// The last import, with no secrets in it.
    public func loadCurrent() throws -> MirrorGeneration? {
        guard FileManager.default.fileExists(atPath: listURL.path) else { return nil }
        return try JSONDecoder().decode(MirrorGeneration.self, from: Data(contentsOf: listURL))
    }

    public func loadCurrentMetadata() throws -> MirrorMetadata? {
        try loadCurrent()?.metadata
    }

    public func sealed() throws -> [Agentkeyring_V2_SealedLogin] {
        guard FileManager.default.fileExists(atPath: sealedURL.path) else { return [] }
        return try Agentkeyring_V2_SealedLogins(serializedBytes: Data(contentsOf: sealedURL)).logins
    }

    /// Saves an import: its secrets are dropped here, and only the sealed copies keep them.
    public func save(_ generation: MirrorGeneration, sealed: [Agentkeyring_V2_SealedLogin]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(generation.redacted).write(to: listURL, options: .atomic)
        try replaceSealed(sealed)
    }

    public func replaceSealed(_ sealed: [Agentkeyring_V2_SealedLogin]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var all = Agentkeyring_V2_SealedLogins()
        all.logins = sealed
        try all.serializedData().write(to: sealedURL, options: .atomic)
    }
}

extension MirrorGeneration {
    /// The same import with every password and one-time code seed removed.
    var redacted: MirrorGeneration {
        MirrorGeneration(id: id, previousGenerationID: previousGenerationID, createdAt: createdAt, sourceExportedAt: sourceExportedAt,
            scope: scope, exporterIdentifier: exporterIdentifier, exporterDisplayName: exporterDisplayName,
            items: items.map(\.redacted), missingItemIDs: missingItemIDs, skippedCredentialCount: skippedCredentialCount,
            skippedCredentialSummary: skippedCredentialSummary)
    }
}

extension MirrorItem {
    var redacted: MirrorItem {
        MirrorItem(id: id, sourceIdentity: sourceIdentity, createdAt: createdAt, lastModifiedAt: lastModifiedAt, title: title,
            subtitle: subtitle, isFavorite: isFavorite, origins: origins, credentials: credentials.map { credential in
                switch credential {
                case let .password(userName, _): .password(userName: userName, password: "")
                case let .totp(_, period, digits, userName, algorithm, issuer):
                    .totp(secret: Data(), period: period, digits: digits, userName: userName, algorithm: algorithm, issuer: issuer)
                }
            })
    }

    /// The secret to seal: the login's one password and one-time code seed.
    var secret: Agentkeyring_V2_LoginSecret {
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = id.uuidString
        secret.username = accountName ?? ""
        let passwords = credentials.compactMap { credential -> String? in
            if case let .password(_, password) = credential { return password }
            return nil
        }
        if passwords.count == 1 { secret.password = passwords[0] }
        let codes = credentials.compactMap { credential -> (Data, UInt16, UInt16, MirrorTOTPAlgorithm)? in
            if case let .totp(seed, period, digits, _, algorithm, _) = credential { return (seed, period, digits, algorithm) }
            return nil
        }
        if codes.count == 1 {
            secret.totpSeed = codes[0].0
            secret.totpPeriodSeconds = Int32(codes[0].1)
            secret.totpDigits = Int32(codes[0].2)
            secret.totpAlgorithm = codes[0].3.rawValue.uppercased()
        }
        return secret
    }
}
