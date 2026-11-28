import Foundation
import OSLog

private let importLogger = Logger(subsystem: "com.agentkeyring.app", category: "Import")

public struct VaultSnapshotMergeResult: Sendable {
    /// The new list. A login whose secret this export supplies holds it, for sealing; the rest hold none.
    public let snapshot: StoredVaultSnapshot
    /// The rules, with any this export changed.
    public let rules: [UUID: LoginRuleTimestampEntry]
    /// The logins whose secret to seal now, at `version`.
    public let sealing: Set<UUID>
    public let version: UInt64
}

public struct VaultSnapshotMerger: Sendable {
    private let idFactory: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        idFactory: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.idFactory = idFactory
        self.now = now
    }

    /// An export from Passwords, merged into the vault like any other
    /// device's vault (CredentialVaultMerge.swift). Every login gets its `LoginIdentity` ID,
    /// so the same login keeps its ID and rule on every export and every
    /// device. A login the export lists twice is kept once. A full
    /// export also finds the logins this device exported before that are gone
    /// from Passwords. A login whose sites or account names changed loses
    /// Automatic: what agents may be given without asking was never chosen for
    /// them. A Blocked login's secret is not kept.
    public func mergeImportedSnapshot(
        previous: StoredVaultSnapshot?,
        importBatch: LoginImportBatch,
        rules: [UUID: LoginRuleTimestampEntry] = [:],
        actor: String = "",
        version: UInt64? = nil
    ) throws -> VaultSnapshotMergeResult {
        try validateUniqueSourceIdentities(importBatch.items)
        let date = now()
        let version = version ?? UInt64(date.timeIntervalSince1970 * 1_000_000_000)

        var exported = CredentialVault()
        var plain: [UUID: StoredVaultLogin] = [:]
        for (item, id) in zip(importBatch.items, LoginIdentity.ids(for: importBatch.items)) {
            if let kept = plain[id] {
                importLogger.notice("An export listed one login twice; the newer copy is kept.")
                guard LoginIdentity.isNewerCopy(item, than: kept) else { continue }
            }
            var stamped = item
            stamped.id = id
            stamped.imports = [LoginSecretRevisionStamp(revision: item.lastModifiedAt, version: version, actor: actor, exportedAt: importBatch.exportedAt)]
            plain[id] = stamped
            exported.items[id] = stamped.redacted
        }

        var earlier = CredentialVault(deleted: previous?.deleted ?? [:])
        for item in previous?.items ?? [] { earlier.items[item.id] = item.redacted }
        for (id, rule) in rules { earlier.rules[id] = LoginRuleTimestampEntry.latest(earlier.rules[id], rule) }
        if importBatch.scope == .full {
            for (id, item) in earlier.items where earlier.isLive(id) && exported.items[id] == nil && !item.isTestPassword
                && (item.imports == nil || item.imports!.contains { $0.actor == actor }) {
                exported.deleted[id] = importBatch.exportedAt
            }
        }

        var merged = CredentialVaultMerge.mergeVaults(earlier, exported)
        for (id, item) in exported.items {
            guard let before = earlier.items[id], merged.rule(for: id) == .automatic,
                  accounts(in: before) != accounts(in: item) || Set(before.origins) != Set(item.origins) else { continue }
            merged.rules[id] = LoginRuleTimestampEntry.set(.ask, replacing: merged.rules[id], at: LoginRuleTimestampEntry.nowMs(date), by: actor)
        }
        merged = merged.deletingBlockedSecrets(at: version)

        let sealing = Set(exported.items.keys.filter { id in
            merged.liveSecret(id).map { $0.version == version && $0.actor == actor } == true
        })
        let items = merged.liveItems.map { item in
            guard sealing.contains(item.id), let secret = plain[item.id] else { return item }
            return StoredVaultLogin(id: item.id, sourceIdentity: item.sourceIdentity, createdAt: item.createdAt,
                lastModifiedAt: item.lastModifiedAt, title: item.title, subtitle: item.subtitle, isFavorite: item.isFavorite,
                origins: item.origins, credentials: secret.credentials, imports: item.imports, secretsDeletedAt: item.secretsDeletedAt)
        }
        let missing = earlier.items.keys.filter { earlier.isLive($0) && !merged.isLive($0) }

        let snapshot = StoredVaultSnapshot(
            id: idFactory(),
            previousSnapshotID: previous?.id,
            createdAt: date,
            sourceExportedAt: importBatch.exportedAt,
            scope: importBatch.scope,
            exporterIdentifier: importBatch.exporterIdentifier,
            exporterDisplayName: importBatch.exporterDisplayName,
            items: items,
            missingItemIDs: missing.sorted { $0.uuidString < $1.uuidString },
            skippedCredentialCount: importBatch.skippedCredentialCount,
            skippedCredentialSummary: importBatch.skippedCredentialSummary,
            deleted: merged.deleted.isEmpty ? nil : merged.deleted
        )
        return VaultSnapshotMergeResult(snapshot: snapshot, rules: merged.rules, sealing: sealing, version: version)
    }

    private func validateUniqueSourceIdentities(_ items: [StoredVaultLogin]) throws {
        var identities = Set<LoginSourceIdentity>()
        for item in items where !identities.insert(item.sourceIdentity).inserted {
            throw VaultStorageError.duplicateSourceIdentity
        }
    }

    private enum CredentialAccount: Hashable {
        case password(String?)
        case totp(String?)
    }

    /// Exactly, so a change of case counts.
    private func accounts(in item: StoredVaultLogin) -> Set<CredentialAccount> {
        Set(item.credentials.map { credential in
            switch credential {
            case let .password(userName, _): CredentialAccount.password(userName)
            case let .totp(_, _, _, userName, _, _): CredentialAccount.totp(userName)
            }
        })
    }
}
