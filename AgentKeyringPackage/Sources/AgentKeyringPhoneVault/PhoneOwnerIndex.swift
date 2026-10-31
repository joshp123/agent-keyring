import AgentKeyringCredentialImport
import AgentKeyringProtocol
import CryptoKit
import Foundation

/// Supplied by pairing after verifying the ApproverKeySet, never by GetIndex itself.
public struct PhoneRuleOwner: Sendable {
    public let keyID: String
    public let publicKey: Data

    public init(keyID: String, publicKey: Data) {
        self.keyID = keyID
        self.publicKey = publicKey
    }
}

public enum PhoneLoginMatch: String, Sendable {
    case sourceIdentity
    case sitesAndAccount
    case needsReview
}

public struct PhoneIndexedLogin: Sendable {
    public let metadata: PhoneVaultItemMetadata
    public let loginID: String
    public let rule: Agentkeyring_V1_AccessRule
    public let match: PhoneLoginMatch
}

struct PhoneOwnerIndex {
    let signed: Agentkeyring_V1_SignedIndex
    let index: Agentkeyring_V1_LoginIndex
    let receivedAt: Date

    init(signed: Agentkeyring_V1_SignedIndex, owner: PhoneRuleOwner, receivedAt: Date) throws {
        let publicKey = try P256.Signing.PublicKey(x963Representation: owner.publicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signed.signature)
        guard !owner.keyID.isEmpty, signed.approverKeyID == owner.keyID,
              publicKey.isValidSignature(signature, for: signed.index) else {
            throw PhoneVaultFailure.invalidOwnerIndex
        }
        let index = try Agentkeyring_V1_LoginIndex(serializedBytes: signed.index)
        let ids = index.logins.map(\.loginID)
        guard index.revision > 0, Set(ids).count == ids.count, !ids.contains(""),
              index.logins.allSatisfy({ [.ask, .automatic, .blocked].contains($0.rule) }),
              index.sources.allSatisfy({ ids.contains($0.loginID) }),
              Set(index.sources.map(\.loginID)).count == index.sources.count else {
            throw PhoneVaultFailure.invalidOwnerIndex
        }
        self.signed = signed
        self.index = index
        self.receivedAt = receivedAt
    }

    func matching(_ items: [PhoneVaultItemMetadata]) -> [PhoneIndexedLogin] {
        let loginsByID = Dictionary(uniqueKeysWithValues: index.logins.map { ($0.loginID, $0) })
        let sources = Dictionary(grouping: index.sources, by: {
            MirrorSourceIdentity(exporterIdentifier: $0.exporterIdentifier, accountID: $0.appleAccountID, itemID: $0.appleItemID)
        })
        let localSources = Dictionary(grouping: items, by: \.sourceIdentity)
        var matched: [UUID: (Agentkeyring_V1_Login, PhoneLoginMatch)] = [:]
        var usedOwnerIDs = Set<String>()
        for item in items {
            if let candidates = sources[item.sourceIdentity], candidates.count == 1,
               localSources[item.sourceIdentity]?.count == 1, let source = candidates.first,
               let login = loginsByID[source.loginID] {
                matched[item.id] = (login, .sourceIdentity)
                usedOwnerIDs.insert(login.loginID)
            }
        }
        let localFallbacks = Dictionary(grouping: items, by: { MatchKey(sites: $0.sites, account: $0.account) })
        let ownerFallbacks = Dictionary(grouping: index.logins, by: { MatchKey(sites: $0.sites, account: $0.account) })
        for item in items where matched[item.id] == nil {
            // An ambiguous source match cannot become a fallback match.
            guard sources[item.sourceIdentity] == nil,
                  let key = MatchKey(sites: item.sites, account: item.account),
                  localFallbacks[key]?.count == 1, let candidates = ownerFallbacks[key], candidates.count == 1,
                  let login = candidates.first, !usedOwnerIDs.contains(login.loginID) else { continue }
            matched[item.id] = (login, .sitesAndAccount)
            usedOwnerIDs.insert(login.loginID)
        }
        return items.map { item in
            guard let (login, method) = matched[item.id] else { return Self.unmatched(item) }
            return PhoneIndexedLogin(metadata: item, loginID: login.loginID, rule: login.rule, match: method)
        }
    }

    static func unmatched(_ metadata: PhoneVaultItemMetadata) -> PhoneIndexedLogin {
        PhoneIndexedLogin(metadata: metadata, loginID: metadata.id.uuidString, rule: .ask, match: .needsReview)
    }

    private struct MatchKey: Hashable {
        let sites: Set<String>
        let account: String

        init?(sites: [String], account: String?) {
            guard !sites.isEmpty, let account, !account.isEmpty else { return nil }
            // Exact saved values, ignoring only order and duplicate sites. No first-site,
            // fuzzy-host or case-insensitive-account match may carry an Automatic rule.
            self.sites = Set(sites)
            self.account = account
        }
    }
}

struct PhoneCachedOwnerIndex: Codable {
    let signedBytes: Data
    let receivedAt: Date
}
