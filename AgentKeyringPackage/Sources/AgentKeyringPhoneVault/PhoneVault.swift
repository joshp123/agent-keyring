import AgentKeyringCredentialImport
import AgentKeyringProtocol
import CryptoKit
import Foundation
import OSLog

private let vaultLogger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Vault")

/// Serial access belongs to the phone's main-actor backend. Import uses only the
/// public key; opening a login requires the caller's authenticated enclave operation.
@MainActor
public final class PhoneVault {
    private let directory: URL
    private var ownerIndex: PhoneOwnerIndex?
    private var manifestURL: URL { directory.appending(path: "manifest.plist") }
    private var ownerIndexURL: URL { directory.appending(path: "owner-index.plist") }

    public init(directory: URL) { self.directory = directory }

    public func status() throws -> PhoneVaultStatus? {
        guard let manifest = try readManifest() else { return nil }
        return PhoneVaultStatus(loginCount: manifest.records.count, importedAt: manifest.importedAt)
    }

    public func importCredentials(_ batch: MirrorImportBatch, publicKey: P256.KeyAgreement.PublicKey) throws -> PhoneVaultStatus {
        vaultLogger.notice("Vault import started")
        let previous = try readManifest()
        if let previous, previous.vaultPublicKey != publicKey.x963Representation { throw PhoneVaultFailure.vaultKeyChanged }
        let merged = try SnapshotMerger().merge(previous: previous?.matchingGeneration, importBatch: batch)
        let incomingSources = Set(batch.items.map(\.sourceIdentity))
        let previousRecords = Dictionary(uniqueKeysWithValues: (previous?.records ?? []).map { ($0.metadata.id, $0) })
        try prepareDirectory()
        vaultLogger.notice("Additive merge completed; received=\(batch.items.count, privacy: .public) total=\(merged.items.count, privacy: .public)")
        var records: [PhoneVaultRecord] = []
        for item in merged.items {
            if incomingSources.contains(item.sourceIdentity) {
                let ciphertextID = UUID()
                let encrypted = try PhoneVaultCiphertext.seal(item, to: publicKey, ciphertextID: ciphertextID)
                try write(PropertyListEncoder().encode(encrypted), to: ciphertextURL(ciphertextID))
                records.append(PhoneVaultRecord(metadata: PhoneVaultItemMetadata(item), ciphertextID: ciphertextID))
            } else if let retained = previousRecords[item.id] {
                records.append(retained)
            } else {
                throw PhoneVaultFailure.loginUnavailable
            }
        }
        vaultLogger.notice("Sealed \(batch.items.count, privacy: .public) imported logins; retained \(records.count - batch.items.count, privacy: .public) existing item files")
        let manifest = PhoneVaultManifest(version: 1, generationID: merged.id, importedAt: merged.createdAt,
                                         sourceExportedAt: batch.exportedAt, vaultPublicKey: publicKey.x963Representation, records: records)
        // Commit last: failures before this leave the entire previous import usable.
        try write(PropertyListEncoder().encode(manifest), to: manifestURL)
        vaultLogger.notice("Committed encrypted phone vault; total=\(records.count, privacy: .public)")
        removeUnreferencedCiphertexts(keeping: Set(records.map(\.ciphertextID)))
        logMatches(manifest.records.map(\.metadata))
        return PhoneVaultStatus(loginCount: records.count, importedAt: manifest.importedAt)
    }

    /// R4.3 calls GetIndex over its pinned connection, then supplies the signed
    /// response and the owner established by R4.5. No trust is learned from the relay.
    public func refreshOwnerIndex(owner: PhoneRuleOwner,
                                  getIndex: () async throws -> Agentkeyring_V1_SignedIndex) async throws {
        try acceptOwnerIndex(try await getIndex(), owner: owner)
    }

    public func acceptOwnerIndex(_ signed: Agentkeyring_V1_SignedIndex, owner: PhoneRuleOwner) throws {
        let candidate = try PhoneOwnerIndex(signed: signed, owner: owner, receivedAt: Date())
        var previous = ownerIndex
        if FileManager.default.fileExists(atPath: ownerIndexURL.path) {
            let cached = try PropertyListDecoder().decode(PhoneCachedOwnerIndex.self, from: Data(contentsOf: ownerIndexURL))
            let stored = try PhoneOwnerIndex(signed: Agentkeyring_V1_SignedIndex(serializedBytes: cached.signedBytes),
                                            owner: owner, receivedAt: cached.receivedAt)
            if previous == nil || stored.index.revision > previous!.index.revision { previous = stored }
        }
        if let previous {
            guard candidate.index.revision >= previous.index.revision else { throw PhoneVaultFailure.staleOwnerIndex }
            if candidate.index.revision == previous.index.revision {
                guard candidate.signed.index == previous.signed.index else { throw PhoneVaultFailure.changedOwnerIndexAtSameRevision }
            }
        }
        try prepareDirectory()
        let cached = PhoneCachedOwnerIndex(signedBytes: try signed.serializedData(), receivedAt: candidate.receivedAt)
        try write(PropertyListEncoder().encode(cached), to: ownerIndexURL)
        ownerIndex = candidate
        vaultLogger.notice("Accepted rule owner's signed index; revision=\(candidate.index.revision, privacy: .public)")
        logMatches(try readManifest()?.records.map(\.metadata) ?? [])
    }

    public var rulesUpdatedAt: Date? { ownerIndex?.receivedAt }
    public var ruleRevision: UInt64? { ownerIndex?.index.revision }

    public func logins() throws -> [PhoneIndexedLogin] {
        let metadata = try readManifest()?.records.map(\.metadata) ?? []
        return ownerIndex?.matching(metadata) ?? metadata.map(PhoneOwnerIndex.unmatched)
    }

    /// Only a matched, current Ask login can be released by this follower. Blocked
    /// and Automatic are not phone approvals; unreviewed imports have no authority.
    public func openAskLogin(loginID: String,
                             keyAgreement: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> MirrorItem {
        guard let login = try logins().first(where: { $0.loginID == loginID && $0.match != .needsReview }),
              login.rule == .ask else { throw PhoneVaultFailure.loginUnavailable }
        return try openLocalLogin(itemID: login.metadata.id, keyAgreement: keyAgreement)
    }

    /// Used for a local, Face ID gated vault inspection, independent of relay authority.
    public func openLocalLogin(itemID: UUID,
                               keyAgreement: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> MirrorItem {
        guard let record = try readManifest()?.records.first(where: { $0.metadata.id == itemID }) else {
            throw PhoneVaultFailure.loginUnavailable
        }
        let encrypted = try PropertyListDecoder().decode(PhoneVaultCiphertext.self, from: Data(contentsOf: ciphertextURL(record.ciphertextID)))
        let item = try encrypted.open(itemID: itemID, ciphertextID: record.ciphertextID, keyAgreement: keyAgreement)
        guard PhoneVaultItemMetadata(item) == record.metadata else { throw PhoneVaultFailure.itemMetadataChanged }
        return item
    }

    private func readManifest() throws -> PhoneVaultManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try PropertyListDecoder().decode(PhoneVaultManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1 else { throw PhoneVaultFailure.unsupportedVersion }
        return manifest
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
    }

    private func ciphertextURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).sealed") }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func removeUnreferencedCiphertexts(keeping ids: Set<UUID>) {
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "sealed" {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            // A cleanup failure does not undo a committed import.
            vaultLogger.error("Encrypted item cleanup failed [\((error as NSError).domain, privacy: .public):\((error as NSError).code, privacy: .public)]")
        }
    }

    private func logMatches(_ items: [PhoneVaultItemMetadata]) {
        let logins = ownerIndex?.matching(items) ?? items.map(PhoneOwnerIndex.unmatched)
        vaultLogger.notice("Owner index matching: source=\(logins.filter { $0.match == .sourceIdentity }.count, privacy: .public) sitesAndAccount=\(logins.filter { $0.match == .sitesAndAccount }.count, privacy: .public) review=\(logins.filter { $0.match == .needsReview }.count, privacy: .public)")
    }
}
