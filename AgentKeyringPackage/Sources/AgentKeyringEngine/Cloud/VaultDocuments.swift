// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// The documents the Macs and iPhones put in iCloud, made and checked the same
// way on both. A device's vault is signed with its reply key: from it other
// devices take its logins, imports and deletions, never its rules, which only
// come in a catalogue signed after Touch ID or Face ID.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation

enum VaultDocumentError: Error { case notTheWriter, unreadable }

public enum VaultDocument {

    /// This device's vault, compressed and signed with its reply key. Secrets and rules are left out.
    public static func signedVaultDocument(_ vault: CredentialVault, signer: PayloadReplySigner) throws -> SignedDocument {
        let bare = CredentialVault(items: vault.items.mapValues(\.redacted), deleted: vault.deleted)
        let protoBytes = try bare.storedProto().serializedData()
        let compressed = try (protoBytes as NSData).compressed(using: .lzfse) as Data
        return try CredentialSealing.signedDocument(CredentialVault.protobufMagic + compressed, by: signer.keyID, sign: signer.sign)
    }

    /// Another device's vault: signed by `writer`, a device in `members`, with its rules dropped.
    public static func opened(_ document: SignedDocument, writer: String, members: Members) throws -> CredentialVault {
        let signer = try CredentialSealing.verifySignedDocument(document, members: members, allowReplyKey: true)
        guard signer.keyID == writer else { throw VaultDocumentError.notTheWriter }
        guard document.payload.starts(with: CredentialVault.protobufMagic) else { throw VaultDocumentError.unreadable }
        let compressed = Data(document.payload.dropFirst(CredentialVault.protobufMagic.count))
        guard let raw = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let proto = try? Agentkeyring_V2_StoredVault(serializedBytes: raw),
              let vault = try? CredentialVault(storedProto: proto) else {
            throw VaultDocumentError.unreadable
        }
        return CredentialVault(items: vault.items.mapValues(\.redacted), deleted: vault.deleted)
    }
}

public enum CloudCopies {
    /// One writer's copies for one device, in records small enough for CloudKit, each a whole SealedLogins.
    public static func records(_ copies: [SealedLogin], for recipient: String, writer: String) throws -> [CloudRecord] {
        var parts: [[SealedLogin]] = [[]]
        var size = 0
        for copy in copies.sorted(by: { $0.loginID < $1.loginID }) {
            let bytes = try copy.serializedData().count + 8
            if size + bytes > CloudVault.partBytes, !parts[parts.count - 1].isEmpty { parts.append([]); size = 0 }
            parts[parts.count - 1].append(copy)
            size += bytes
        }
        return try parts.enumerated().map { index, part in
            var batch = Agentkeyring_V2_SealedLogins()
            batch.logins = part
            return CloudRecord(name: name(recipient: recipient, writer: writer, part: index), kind: CloudRecordKind.copies(recipient),
                               writer: writer, payload: try batch.serializedData())
        }
    }

    public static func name(recipient: String, writer: String, part: Int) -> String {
        "\(CloudRecordKind.copies(recipient))-\(writer)-\(part)"
    }

    /// The names of this writer's parts for a device beyond the ones just written: left from a longer list.
    public static func stale(_ held: Set<String>, recipient: String, writer: String, written: Int) -> [String] {
        let prefix = "\(CloudRecordKind.copies(recipient))-\(writer)-"
        return held.filter { name in
            name.hasPrefix(prefix) && (Int(name.dropFirst(prefix.count)).map { $0 >= written } ?? false)
        }.sorted()
    }

    /// The recipient, writer and part a copies record's name says.
    public static func parse(_ name: String) -> (recipient: String, writer: String, part: Int)? {
        guard name.hasPrefix("copies-") else { return nil }
        let parts = name.dropFirst("copies-".count).split(separator: "-")
        guard parts.count == 3, let part = Int(parts[2]) else { return nil }
        return (String(parts[0]), String(parts[1]), part)
    }

    /// This writer's records for a device no longer in the list, or for one it now has no copies for.
    static func orphaned(_ held: Set<String>, writer: String, keeping recipients: Set<String>) -> [String] {
        held.filter { name in parse(name).map { $0.writer == writer && !recipients.contains($0.recipient) } ?? false }.sorted()
    }

    /// Copies sealed to `recipient` that a device in `members` signed, of the catalogue's current version
    /// of each login, and never of one whose secret no device holds.
    public static func checked(_ payload: Data, for recipient: String, members: Members, catalogue: Catalogue) -> [SealedLogin] {
        guard let batch = try? Agentkeyring_V2_SealedLogins(serializedBytes: payload) else { return [] }
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        return batch.logins.filter { copy in
            guard copy.openerID == recipient, let login = listed[copy.loginID], login.holdsSecret else { return false }
            return (try? CredentialSealing.verifySealedLogin(copy, members: members, listed: login)) != nil
        }
    }
}

public enum CloudMembers {
    /// Signed Members with every revision before it, for a device that has missed some.
    public static func payload(current: Data, history: [Data]) throws -> Data {
        var bundle = Agentkeyring_V2_Bundle()
        bundle.members = try SignedDocument(serializedBytes: current)
        bundle.membersSince = history.compactMap { try? SignedDocument(serializedBytes: $0) }
        return try bundle.serializedData()
    }

    /// The revisions in a payload, oldest first, ending with the current one.
    public static func revisions(_ payload: Data) -> [SignedDocument] {
        guard let bundle = try? Agentkeyring_V2_Bundle(serializedBytes: payload) else { return [] }
        var all = bundle.membersSince
        if bundle.hasMembers, all.last != bundle.members { all.append(bundle.members) }
        return all.sorted { revision($0) < revision($1) }
    }

    public static func revision(_ document: SignedDocument) -> UInt64 {
        (try? Members(serializedBytes: document.payload))?.revision ?? 0
    }

    /// The newest revision in a payload this device can follow, with its signed document: from one it holds
    /// (`history`, every signed Members it keeps, its current one included) or one a device in `members` signed,
    /// each later one checked against the one before. Nil when none of it is this keyring's. A revision that
    /// does not follow (forged, or with a huge revision) counts for nothing.
    static func followedDocument(_ payload: Data, members: Members, history: [Data]) -> (members: Members, document: SignedDocument)? {
        let held = Set(history.compactMap { try? SignedDocument(serializedBytes: $0) }.map { $0.payload + $0.signature })
        var followed: (Members, SignedDocument)?
        for document in revisions(payload) {
            if let current = followed?.0, let next = try? CredentialSealing.verifySignedMembers(document, current: current) {
                followed = (next, document)
            } else if held.contains(document.payload + document.signature) || (try? CredentialSealing.verifySignedDocument(document, members: members)) != nil,
                      let listed = try? Members(serializedBytes: document.payload), listed.revision >= (followed?.0.revision ?? 0) {
                followed = (listed, document)
            }
        }
        return followed
    }

    static func followed(_ payload: Data, members: Members, history: [Data]) -> Members? {
        followedDocument(payload, members: members, history: history)?.members
    }

    /// True if iCloud holds another keyring's real list: none of it this keyring's, and its newest revision
    /// signed by a device it names. An offline device set up on its own must never write over it.
    public static func isAnotherKeyring(_ payload: Data, members: Members, history: [Data]) -> Bool {
        guard followed(payload, members: members, history: history) == nil, let newest = revisions(payload).last,
              let listed = try? Members(serializedBytes: newest.payload), listed.domain == "agentkeyring.members.v2" else { return false }
        return (try? CredentialSealing.verifySignedDocument(newest, members: listed)) != nil
    }

    /// Whether this device's list at `revision` may be written over the one in iCloud: only when the newest
    /// followed revision on iCloud is an older signed ancestor on this device's own history (never a forked
    /// branch, even at a lower revision, and never another keyring's real list); anything else (unreadable,
    /// or a list that does not check) always, so a forged record never stops the devices writing theirs.
    public static func mayReplace(_ payload: Data, with revision: UInt64, members: Members, history: [Data]) -> Bool {
        if let (followed, document) = followedDocument(payload, members: members, history: history) {
            let held = Set(history.compactMap { try? SignedDocument(serializedBytes: $0) }.map { $0.payload + $0.signature })
            return followed.revision < revision && held.contains(document.payload + document.signature)
        }
        return !isAnotherKeyring(payload, members: members, history: history)
    }

    /// Stricter check for an edit based on `members` (`base` bytes): allows replacement only when the newest
    /// followed revision on iCloud is this exact base or a signed ancestor of it on `history` (ignoring any
    /// unverified trailing forged entries, and never overwriting a forked branch at any revision).
    public static func mayReplaceBase(_ payload: Data, base: Data?, members: Members, history: [Data]) -> Bool {
        if isAnotherKeyring(payload, members: members, history: history) { return false }
        guard let (followed, document) = followedDocument(payload, members: members, history: history) else { return true }
        let ancestors = Set((history + (base.map { [$0] } ?? [])).compactMap { try? SignedDocument(serializedBytes: $0) }.map { $0.payload + $0.signature })
        return followed.revision <= members.revision && ancestors.contains(document.payload + document.signature)
    }
}

extension Catalogue {
    /// The rules as the vault keeps them, by login ID.
    public var rules: [UUID: LoginRuleTimestampEntry] {
        Dictionary(logins.compactMap { login -> (UUID, LoginRuleTimestampEntry)? in
            guard let id = UUID(uuidString: login.loginID) else { return nil }
            return (id, LoginRuleTimestampEntry(LoginRule(storedRule: login.rule), updatedAtMs: login.ruleUpdatedUnixMs, actor: login.ruleActor))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// A catalogue's revision, if one of the devices in `members` signed it; 0 otherwise.
    static func trustedRevision(_ payload: Data, members: Members) -> UInt64 {
        trusted(payload, members: members)?.revision ?? 0
    }

    /// The catalogue, if one of the devices in `members` signed it.
    public static func trusted(_ payload: Data, members: Members) -> Catalogue? {
        guard let signed = try? SignedDocument(serializedBytes: payload), (try? CredentialSealing.verifySignedDocument(signed, members: members)) != nil else { return nil }
        return try? Catalogue(serializedBytes: signed.payload)
    }
}

/// The signed catalogue this device offers iCloud: its bytes, and the notice keys it is sealed to.
public struct SubmittedCatalogue: Sendable {
    public var signedBytes: Data
    public var recipients: [String: P256.KeyAgreement.PublicKey]

    public init(signedBytes: Data, recipients: [String: P256.KeyAgreement.PublicKey]) {
        self.signedBytes = signedBytes
        self.recipients = recipients
    }
}

/// Shared CloudKit catalogue replacement and sealing checks for Mac and iPhone peers.
public enum CloudCatalogue {
    /// True if `existingPayload` in iCloud may be replaced by our `submitted` catalogue: when the existing
    /// catalogue gives way to it (`givesWay`), or holds the same bytes with stale `CloudEnvelope` recipients
    /// and all current member keys are available for re-sealing.
    public static func shouldReplace(
        _ existingPayload: Data,
        with submitted: SubmittedCatalogue,
        members: Members,
        deviceID: String,
        opener: CloudEnvelope.KeyOpener
    ) -> Bool {
        guard let opened = CloudEnvelope.openCloudEnvelope(
            existingPayload,
            expectedKind: CloudRecordKind.catalogue,
            deviceID: deviceID,
            opener: opener
        ) else {
            return false
        }
        if let next = (try? SignedDocument(serializedBytes: submitted.signedBytes)).flatMap({ try? Catalogue(serializedBytes: $0.payload) }),
           givesWay(opened.plaintext, to: next, members: members) {
            return true
        }
        if opened.plaintext == submitted.signedBytes,
           !isSealCurrent(opened, members: members, recipients: submitted.recipients) {
            return true
        }
        return false
    }

    /// True if a catalogue in iCloud may be written over by `next`: no device in `members` signed it, or it is of
    /// an earlier revision and sets no rule `next` has not seen. One that does is taken in instead, and kept
    /// beside the held one until a device signs their merge.
    public static func givesWay(_ existing: Data, to next: Catalogue, members: Members) -> Bool {
        guard let held = Catalogue.trusted(existing, members: members) else { return true }
        return held.revision < next.revision && CatalogueMerge.isDominated(held, by: next)
    }

    /// True if an opened iCloud catalogue envelope already matches every Mac and iPhone notice key in `members`.
    static func isSealCurrent(
        _ opened: OpenedCloudEnvelope,
        members: Members,
        recipients: [String: P256.KeyAgreement.PublicKey]
    ) -> Bool {
        let memberDevices = CloudEnvelope.memberDeviceIDs(in: members)
        guard !memberDevices.isEmpty, memberDevices.isSubset(of: Set(recipients.keys)) else { return false }
        return !CloudEnvelope.needsReseal(
            existingRecipientKeys: opened.recipientKeyFingerprints,
            expectedRecipients: recipients,
            memberDevices: memberDevices
        )
    }
}

enum CloudPushRegistrationError: Error, Equatable, Sendable {
    case invalidDocument
    case invalidFields
    case invalidSignature
    case unauthorizedSigner
}

public struct VerifiedPushRegistration: Sendable, Equatable {
    public let registration: Agentkeyring_V2_PushRegistration
    public let target: Agentkeyring_V2_Device
    public let signer: Agentkeyring_V2_Device

    public init(
        registration: Agentkeyring_V2_PushRegistration,
        target: Agentkeyring_V2_Device,
        signer: Agentkeyring_V2_Device
    ) {
        self.registration = registration
        self.target = target
        self.signer = signer
    }
}

/// Shared verification and recency checks for signed `PushRegistration` records in iCloud.
public enum CloudPushRegistration {

    /// Verifies a signed `PushRegistration` against `members` (device's own reply key, or its iPhone's
    /// reply key for an Apple Watch) and validates its APNs fields and notice public key.
    public static func verified(_ payload: Data, members: Members) throws -> VerifiedPushRegistration {
        guard let signed = try? SignedDocument(serializedBytes: payload),
              let registration = try? Agentkeyring_V2_PushRegistration(serializedBytes: signed.payload),
              registration.domain == "agentkeyring.push.v2" else {
            throw CloudPushRegistrationError.invalidDocument
        }
        guard !registration.apnsToken.isEmpty,
              !registration.apnsTopic.isEmpty,
              (try? P256.KeyAgreement.PublicKey(x963Representation: registration.noticePublicKey)) != nil else {
            throw CloudPushRegistrationError.invalidFields
        }
        guard let signer = try? CredentialSealing.verifySignedDocument(signed, members: members, allowReplyKey: true),
              signed.signerKeyID == signer.replyKeyID else {
            throw CloudPushRegistrationError.invalidSignature
        }
        guard let target = members.devices.first(where: { $0.keyID == registration.deviceKeyID }),
              target.keyID == signer.keyID || (target.kind == .watch && signer.kind == .iphone) else {
            throw CloudPushRegistrationError.unauthorizedSigner
        }
        return VerifiedPushRegistration(registration: registration, target: target, signer: signer)
    }

    /// True if `registration` should replace an existing serialized signed registration:
    /// later timestamp, then greater serialized registration bytes for the same second.
    public static func isNewer(_ registration: Agentkeyring_V2_PushRegistration, than existingPayload: Data?) -> Bool {
        guard let existingPayload,
              let existingSigned = try? SignedDocument(serializedBytes: existingPayload),
              let existing = try? Agentkeyring_V2_PushRegistration(serializedBytes: existingSigned.payload) else {
            return true
        }
        if registration.registeredUnixSeconds != existing.registeredUnixSeconds {
            return registration.registeredUnixSeconds > existing.registeredUnixSeconds
        }
        guard let incomingBytes = try? registration.serializedData(),
              let existingBytes = try? existing.serializedData() else { return false }
        return existingBytes.lexicographicallyPrecedes(incomingBytes)
    }
}

extension CredentialVault {
    /// The logins as the signed catalogue lists them, with these rules. `fresh` names the version of each
    /// login this device has just sealed; any other keeps the version `previous` gave it, so a login
    /// another device imported is never listed as having no secret. Blocked and deleted ones list none.
    public func catalogueLogins(rules: [UUID: LoginRuleTimestampEntry], fresh: [String: UInt64], previous: Catalogue?) -> [Agentkeyring_V2_Login] {
        let before = Dictionary((previous?.logins ?? []).map { ($0.loginID, $0.version) }, uniquingKeysWith: { first, _ in first })
        return liveItems.map { item in
            var login = Agentkeyring_V2_Login()
            login.loginID = item.id.uuidString
            login.title = item.title
            login.sites = item.origins
            login.account = item.accountName ?? ""
            login.hasOneTimeCode_p = item.credentials.contains { if case .totp = $0 { true } else { false } }
            let entry = rules[item.id]
            login.rule = (entry?.rule ?? .ask).storedRule
            login.ruleUpdatedUnixMs = entry?.updatedAtMs ?? 0
            login.ruleActor = entry?.actor ?? ""
            let id = login.loginID
            login.version = login.rule == .blocked || item.secretDeleted ? 0 : fresh[id] ?? before[id] ?? 0
            return login
        }
    }
}

extension StoredVaultLogin {
    /// The secret to seal: the login's one password and one-time code seed.
    public var secret: LoginSecret {
        var secret = LoginSecret()
        secret.loginID = id.uuidString
        secret.username = accountName ?? ""
        secret.title = title
        secret.sites = origins
        let passwords = credentials.compactMap { credential -> String? in
            if case let .password(_, password) = credential { return password }
            return nil
        }
        if passwords.count == 1 { secret.password = passwords[0] }
        let codes = credentials.compactMap { credential -> (Data, UInt16, UInt16, OneTimeCodeAlgorithm)? in
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
