// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// The vault every Mac and iPhone keeps, and how two of them merge. No device
// is in charge: each keeps, for each login, the newest of every part, so two
// vaults merged in any order, any number of times, end the same. A secret is
// never in here, only which import of it each device holds; the sealed copies
// carry the same version.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import Foundation
import SwiftProtobuf

extension LoginRule {
    /// For two rules set at the same moment: the safer one stays.
    fileprivate var strictness: Int {
        switch self {
        case .automatic: 0
        case .ask: 1
        case .blocked: 2
        }
    }
}

/// A login's rule, with when and where it was set.
public struct LoginRuleTimestampEntry: Equatable, Sendable {
    public let rule: LoginRule
    /// Unix milliseconds; 0 for a rule set before these were kept.
    public let updatedAtMs: Int64
    /// The device that set it (`Device.key_id`); empty when not known.
    public let actor: String

    public init(_ rule: LoginRule, updatedAtMs: Int64, actor: String) {
        self.rule = rule
        self.updatedAtMs = updatedAtMs
        self.actor = actor
    }

    /// The later wins, then the safer rule (Block over Ask over Automatic), then the higher device key.
    public static func latest(_ a: LoginRuleTimestampEntry?, _ b: LoginRuleTimestampEntry?) -> LoginRuleTimestampEntry? {
        guard let a, let b else { return a ?? b }
        return (a.updatedAtMs, a.rule.strictness, a.actor) >= (b.updatedAtMs, b.rule.strictness, b.actor) ? a : b
    }

    static func nowMs(_ date: Date = .now) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// A new rule set on this device: later than any it replaces, even with this device's clock behind.
    public static func set(_ rule: LoginRule, replacing local: LoginRuleTimestampEntry?, at nowMs: Int64, by actor: String) -> LoginRuleTimestampEntry {
        LoginRuleTimestampEntry(rule, updatedAtMs: max(nowMs, (local?.updatedAtMs ?? 0) + 1), actor: actor)
    }

    /// A login's rule in another device's signed catalogue, against the catalogue that device started from
    /// (`base`, the one this device last served), merged into this device's rule: unchanged, it is no edit;
    /// changed, the later of the two stays.
    public static func received(_ incoming: LoginRuleTimestampEntry, base: LoginRuleTimestampEntry?, local: LoginRuleTimestampEntry?) -> LoginRuleTimestampEntry? {
        incoming == base ? local : latest(local, incoming)
    }
}

public struct CredentialVault: Equatable, Sendable {
    /// Each login without its secret, by `LoginIdentity` ID.
    public var items: [UUID: StoredVaultLogin]
    public var rules: [UUID: LoginRuleTimestampEntry]
    /// When an export from Passwords found each login gone.
    public var deleted: [UUID: Date]

    public init(items: [UUID: StoredVaultLogin] = [:], rules: [UUID: LoginRuleTimestampEntry] = [:], deleted: [UUID: Date] = [:]) {
        self.items = items
        self.rules = rules
        self.deleted = deleted
    }

    public func rule(for id: UUID) -> LoginRule { rules[id]?.rule ?? .ask }

    /// Still in Passwords: changed, or in an export made since the export
    /// that found it gone, if one did. An older export imported late is not.
    public func isLive(_ id: UUID) -> Bool {
        guard let item = items[id] else { return false }
        guard let gone = deleted[id] else { return true }
        let exported = (item.imports ?? []).map { $0.exportedAt ?? Date(timeIntervalSince1970: Double($0.version) / 1_000_000_000) }
        return ([item.lastModifiedAt ?? item.createdAt ?? .distantPast] + exported).max()! > gone
    }

    var liveItems: [StoredVaultLogin] {
        items.keys.filter(isLive).sorted { $0.uuidString < $1.uuidString }.compactMap { items[$0] }
    }

    /// The import whose sealed copies agents may be given: of this revision
    /// of the login, not deleted by Blocked, the newest. Nil when the login is
    /// Blocked or no device holds its secret.
    public func liveSecret(_ id: UUID) -> LoginSecretRevisionStamp? {
        guard rule(for: id) != .blocked, let item = items[id] else { return nil }
        return item.liveImport
    }

    /// Blocking deletes the secret on every device: every import so far is
    /// marked deleted, so neither an older vault nor unblocking brings it back.
    /// Only a new export from Passwords does.
    public func deletingBlockedSecrets(at version: UInt64) -> CredentialVault {
        var next = self
        for (id, item) in items where rule(for: id) == .blocked {
            let newest = ([version, item.secretsDeletedAt ?? 0] + (item.imports ?? []).map(\.version)).max() ?? version
            next.items[id]?.secretsDeletedAt = newest
        }
        return next
    }
}

extension StoredVaultLogin {
    /// The import of this revision not deleted by Blocked, newest revision
    /// first, then newest import; the rule is the vault's to check.
    var liveImport: LoginSecretRevisionStamp? {
        (imports ?? []).filter { stamp in
            stamp.version > (secretsDeletedAt ?? 0) && CredentialVaultMerge.isSameRevision(stamp.revision, lastModifiedAt)
        }.max { $1.isNewer(than: $0) }
    }

    /// No device holds its secret: deleted when it was Blocked, and not exported from Passwords since.
    public var secretDeleted: Bool { secretsDeletedAt != nil && liveImport == nil }

    /// The same login with every password and one-time code seed removed.
    public var redacted: StoredVaultLogin {
        var copy = StoredVaultLogin(id: id, sourceIdentity: sourceIdentity, createdAt: createdAt, lastModifiedAt: lastModifiedAt, title: title,
            subtitle: subtitle, isFavorite: isFavorite, origins: origins, credentials: credentials.map { credential in
                switch credential {
                case let .password(userName, _): .password(userName: userName, password: "")
                case let .totp(_, period, digits, userName, algorithm, issuer):
                    .totp(secret: Data(), period: period, digits: digits, userName: userName, algorithm: algorithm, issuer: issuer)
                }
            })
        copy.imports = imports
        copy.secretsDeletedAt = secretsDeletedAt
        return copy
    }
}

extension StoredVaultSnapshot {
    /// These logins' secrets deleted, as Blocking does: every import of them up to `version`.
    public func deletingSecrets(of ids: Set<UUID>, at version: UInt64) -> StoredVaultSnapshot {
        var vault = CredentialVault()
        for item in items { vault.items[item.id] = item }
        for id in ids { vault.rules[id] = LoginRuleTimestampEntry(.blocked, updatedAtMs: 0, actor: "") }
        let deleted = vault.deletingBlockedSecrets(at: version)
        var copy = self
        copy.items = items.map { deleted.items[$0.id] ?? $0 }
        return copy
    }

    /// Its logins as a vault, without rules.
    public var vault: CredentialVault {
        CredentialVault(items: Dictionary(items.map { ($0.id, $0.redacted) }, uniquingKeysWith: { first, _ in first }), deleted: deleted ?? [:])
    }

    /// Another device's vault folded in: every login, import and deletion it knows of. Its rules are
    /// not taken: they come only in a signed catalogue.
    public func folding(_ peer: CredentialVault) -> StoredVaultSnapshot {
        let merged = CredentialVaultMerge.mergeVaults(vault, CredentialVault(items: peer.items.mapValues(\.redacted), deleted: peer.deleted))
        var copy = self
        copy.items = merged.liveItems
        copy.deleted = merged.deleted.isEmpty ? nil : merged.deleted
        return copy
    }

    /// The same import with every password and one-time code seed removed.
    public var redacted: StoredVaultSnapshot {
        var copy = self
        copy.items = items.map(\.redacted)
        return copy
    }
}

public enum CredentialVaultMerge {
    /// Passwords on two devices records the same unchanged login up to a few
    /// hundred milliseconds apart; within this, two times are one revision.
    static let sameRevisionWindow: TimeInterval = 2

    public static func isSameRevision(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == b }
        return abs(a.timeIntervalSince(b)) <= sameRevisionWindow
    }

    /// Commutative, associative and idempotent: every part is the newest of
    /// the two by an order every device works out the same way.
    public static func mergeVaults(_ a: CredentialVault, _ b: CredentialVault) -> CredentialVault {
        CredentialVault(items: a.items.merging(b.items) { mergeLoginMetadata($0, $1) },
              rules: a.rules.merging(b.rules) { LoginRuleTimestampEntry.latest($0, $1)! },
              deleted: a.deleted.merging(b.deleted) { max($0, $1) })
    }

    /// One login from two vaults: the newer revision's details (by when
    /// Passwords last changed it, exactly), each device's newest import, and
    /// the latest deletion by Blocked.
    static func mergeLoginMetadata(_ a: StoredVaultLogin, _ b: StoredVaultLogin) -> StoredVaultLogin {
        var merged = isOrderedBefore(a, b) ? b : a
        var byActor: [String: LoginSecretRevisionStamp] = [:]
        for stamp in (a.imports ?? []) + (b.imports ?? []) {
            if let held = byActor[stamp.actor], !stamp.isNewer(than: held) { continue }
            byActor[stamp.actor] = stamp
        }
        merged.imports = a.imports == nil && b.imports == nil ? nil : byActor.values.sorted { $0.actor < $1.actor }
        let deletedAt = [a.secretsDeletedAt, b.secretsDeletedAt].compactMap { $0 }.max()
        merged.secretsDeletedAt = deletedAt
        return merged
    }

    /// When Passwords last changed it, then all its details, so a tie still ends the same everywhere.
    private static func isOrderedBefore(_ a: StoredVaultLogin, _ b: StoredVaultLogin) -> Bool {
        let aTime = a.lastModifiedAt?.timeIntervalSince1970 ?? -.infinity
        let bTime = b.lastModifiedAt?.timeIntervalSince1970 ?? -.infinity
        if aTime != bTime { return aTime < bTime }
        return detailsBytes(a).lexicographicallyPrecedes(detailsBytes(b))
    }

    private static func detailsBytes(_ item: StoredVaultLogin) -> Data {
        var details = item.redacted
        details.imports = nil
        details.secretsDeletedAt = nil
        var options = BinaryEncodingOptions()
        options.useDeterministicOrdering = true
        return (try? details.storedProto().serializedData(options: options)) ?? Data()
    }
}

extension CredentialVault {
    public static let protobufMagic = Data("AKRVLT02".utf8)

    public func encodeProtobuf() throws -> Data {
        Self.protobufMagic + (try storedProto().serializedData())
    }

    public static func decodeProtobuf(_ data: Data) throws -> CredentialVault {
        guard data.starts(with: protobufMagic) else { throw StoredVaultCodecError.invalidMagic }
        let proto = try Agentkeyring_V2_StoredVault(serializedBytes: Data(data.dropFirst(protobufMagic.count)))
        return try CredentialVault(storedProto: proto)
    }

    public init(storedProto proto: Agentkeyring_V2_StoredVault) throws {
        var items: [UUID: StoredVaultLogin] = [:]
        for storedItem in proto.items {
            let item = try StoredVaultLogin(storedProto: storedItem)
            items[item.id] = item
        }
        var rules: [UUID: LoginRuleTimestampEntry] = [:]
        for storedRule in proto.rules {
            guard let id = UUID(uuidString: storedRule.loginID) else {
                throw StoredVaultCodecError.invalidUUID("Vault.rules")
            }
            let entry = LoginRuleTimestampEntry(
                LoginRule(storedRule: storedRule.rule),
                updatedAtMs: storedRule.updatedAtMs,
                actor: storedRule.actor
            )
            rules[id] = LoginRuleTimestampEntry.latest(rules[id], entry)
        }
        var deleted: [UUID: Date] = [:]
        for (rawID, seconds) in proto.deletedUnixSeconds {
            guard let id = UUID(uuidString: rawID) else {
                throw StoredVaultCodecError.invalidUUID("Vault.deleted")
            }
            deleted[id] = Date(timeIntervalSince1970: seconds)
        }
        self.init(items: items, rules: rules, deleted: deleted)
    }

    public func storedProto() -> Agentkeyring_V2_StoredVault {
        var proto = Agentkeyring_V2_StoredVault()
        proto.items = items.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { items[$0]?.storedProto() }
        proto.rules = rules.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let entry = rules[id] else { return nil }
            var stored = Agentkeyring_V2_StoredRuleEntry()
            stored.loginID = id.uuidString
            stored.rule = entry.rule.storedRule
            stored.updatedAtMs = entry.updatedAtMs
            stored.actor = entry.actor
            return stored
        }
        proto.deletedUnixSeconds = Dictionary(
            uniqueKeysWithValues: deleted.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }
        )
        return proto
    }
}

extension LoginRule {
    public init(storedRule rule: Agentkeyring_V2_Rule) {
        switch rule {
        case .automatic: self = .automatic
        case .blocked: self = .blocked
        case .ask, .unspecified, .UNRECOGNIZED: self = .ask
        }
    }

    var storedRule: Agentkeyring_V2_Rule {
        switch self {
        case .ask: .ask
        case .automatic: .automatic
        case .blocked: .blocked
        }
    }
}
