// Written by AI on 2026.11.25 by model gemini-4-neon; edited on 2026.11.27 by model gemini-4-hydrogen.
//
// End-to-end encryption for shared metadata records in the user's iCloud
// private database (`catalogue`, `vault-*`, `mailbox-*`), so Apple cannot read
// site names, account names, rules, or update mailbox keys even when Advanced
// Data Protection is off.
//
// Each payload is encrypted with a fresh random 256-bit AES-GCM content key,
// and that content key is HPKE-wrapped (P256_SHA256_AES_GCM_256) to every
// enrolled Mac and iPhone's non-biometric `noticePublicKey` (so background
// iCloud sync needs no Touch ID or Face ID prompt). The header (record kind
// and recipient key list) is bound into the GCM AAD so CloudKit cannot swap
// record kinds or strip recipients without breaking authentication.
//
// Wire format (v2 protobuf):
//   magic (8 bytes: "AKRCLD02")
//   serialized CloudEnvelope (header_bytes = serialized CloudEnvelopeHeader, ciphertext = AES-GCM combined)

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation

public enum CloudEnvelopeError: Error, Equatable {
    case noRecipients
    case missingRecipientKey
    case invalidFormat
    case wrongKind
    case noRecipientEntry
}

public struct OpenedCloudEnvelope: Sendable, Equatable {
    public let plaintext: Data
    public let recipientIDs: Set<String>
    public let recipientKeyFingerprints: [String: Data]

    public init(plaintext: Data, recipientIDs: Set<String>, recipientKeyFingerprints: [String: Data]) {
        self.plaintext = plaintext
        self.recipientIDs = recipientIDs
        self.recipientKeyFingerprints = recipientKeyFingerprints
    }
}

public enum CloudEnvelope {

    public typealias KeyOpener = @Sendable (_ encapsulatedKey: Data, _ ciphertext: Data, _ info: Data, _ authenticating: Data) throws -> Data

    private static let magicV2 = Data("AKRCLD02".utf8)
    private static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    private static let keyInfo = Data("agentkeyring.cloud-key.v1".utf8)
    private static let payloadDomain = Data("agentkeyring.cloud-payload.v1".utf8)
    private static let maxHeaderBytes = 256 * 1024

    /// Opens an HPKE-wrapped content key using a P-256 key-agreement private key (software or Secure Enclave).
    public static func hpkeOpen<Key: HPKEDiffieHellmanPrivateKey>(
        encapsulatedKey: Data,
        ciphertext: Data,
        info: Data,
        authenticating aad: Data,
        with key: Key
    ) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info, encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext, authenticating: aad)
    }

    public static func isSealed(_ data: Data) -> Bool {
        data.count > magicV2.count && data.starts(with: magicV2)
    }

    /// Short 16-byte SHA-256 fingerprint of a recipient's P-256 notice public key so
    /// reseal checks detect key rotation for an existing device ID.
    static func keyFingerprint(of publicKey: P256.KeyAgreement.PublicKey) -> Data {
        Data(SHA256.hash(data: publicKey.x963Representation).prefix(16))
    }

    /// Encrypts `plaintext` for every device in `recipients` (keyed by `Device.keyID`) using v2 protobuf format.
    public static func seal(
        _ plaintext: Data,
        kind: String,
        recipients: [String: P256.KeyAgreement.PublicKey]
    ) throws -> Data {
        guard !recipients.isEmpty else { throw CloudEnvelopeError.noRecipients }
        let contentKey = SymmetricKey(size: .bits256)
        let rawKey = contentKey.withUnsafeBytes { Data($0) }
        let entries: [Agentkeyring_V2_CloudEnvelopeRecipient] = try recipients.keys.sorted().map { deviceID in
            let publicKey = recipients[deviceID]!
            var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: suite, info: keyInfo)
            let wrapped = try sender.seal(rawKey, authenticating: keyAAD(kind: kind, deviceID: deviceID))
            var recipient = Agentkeyring_V2_CloudEnvelopeRecipient()
            recipient.deviceID = deviceID
            recipient.keyFingerprint = keyFingerprint(of: publicKey)
            recipient.encapsulatedKey = sender.encapsulatedKey
            recipient.wrappedKey = wrapped
            return recipient
        }
        var header = Agentkeyring_V2_CloudEnvelopeHeader()
        header.kind = kind
        header.recipients = entries
        let headerBytes = try header.serializedData()
        let sealedBox = try AES.GCM.seal(plaintext, using: contentKey, authenticating: payloadAAD(kind: kind, header: headerBytes))
        guard let combined = sealedBox.combined else { throw CloudEnvelopeError.invalidFormat }
        var envelope = Agentkeyring_V2_CloudEnvelope()
        envelope.headerBytes = headerBytes
        envelope.ciphertext = combined
        return magicV2 + (try envelope.serializedData())
    }

    /// Decrypts a `CloudEnvelope` addressed to `deviceID` for `expectedKind`.
    /// Returns nil if the envelope is malformed, targets another kind, has no entry for `deviceID`,
    /// or fails HPKE / AES-GCM authentication.
    public static func openCloudEnvelope(
        _ data: Data,
        expectedKind: String,
        deviceID: String,
        opener: KeyOpener
    ) -> OpenedCloudEnvelope? {
        guard isSealed(data),
              let envelope = try? Agentkeyring_V2_CloudEnvelope(serializedBytes: Data(data.dropFirst(magicV2.count))),
              !envelope.headerBytes.isEmpty,
              envelope.headerBytes.count <= maxHeaderBytes,
              let header = try? Agentkeyring_V2_CloudEnvelopeHeader(serializedBytes: envelope.headerBytes),
              header.kind == expectedKind,
              let entry = header.recipients.first(where: { $0.deviceID == deviceID }) else {
            return nil
        }
        guard let rawKey = try? opener(entry.encapsulatedKey, entry.wrappedKey, keyInfo, keyAAD(kind: expectedKind, deviceID: deviceID)),
              rawKey.count == 32,
              let box = try? AES.GCM.SealedBox(combined: envelope.ciphertext),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: rawKey), authenticating: payloadAAD(kind: expectedKind, header: envelope.headerBytes)) else {
            return nil
        }
        let ids = Set(header.recipients.map(\.deviceID))
        let fingerprints = Dictionary(
            header.recipients.map { ($0.deviceID, $0.keyFingerprint) },
            uniquingKeysWith: { _, latest in latest }
        )
        return OpenedCloudEnvelope(plaintext: plaintext, recipientIDs: ids, recipientKeyFingerprints: fingerprints)
    }

    /// True if a record holding the exact same plaintext should be re-sealed and written to iCloud.
    public static func needsReseal(
        existingRecipientKeys: [String: Data],
        expectedRecipients: [String: P256.KeyAgreement.PublicKey],
        memberDevices: Set<String>
    ) -> Bool {
        let expectedFingerprints = expectedRecipients.filter { memberDevices.contains($0.key) }
            .mapValues { keyFingerprint(of: $0) }
        return existingRecipientKeys != expectedFingerprints
    }

    /// Every Mac and iPhone listed in `members` (Apple Watch never reads CloudKit).
    static func memberDeviceIDs(in members: Members) -> Set<String> {
        Set(members.devices.filter { $0.kind != .watch }.map(\.keyID))
    }

    /// Notice keys authenticated by the signed membership list.
    public static func recipients(for members: Members) -> [String: P256.KeyAgreement.PublicKey] {
        var result: [String: P256.KeyAgreement.PublicKey] = [:]
        for device in members.devices where device.kind != .watch {
            result[device.keyID] = try? P256.KeyAgreement.PublicKey(x963Representation: device.noticePublicKey)
        }
        return result
    }

    private static func keyAAD(kind: String, deviceID: String) -> Data {
        lengthPrefixed(Data(kind.utf8)) + lengthPrefixed(Data(deviceID.utf8))
    }

    private static func payloadAAD(kind: String, header: Data) -> Data {
        payloadDomain + lengthPrefixed(Data(kind.utf8)) + lengthPrefixed(header)
    }

    private static func lengthPrefixed(_ part: Data) -> Data {
        var length = UInt32(part.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + part
    }
}

enum CloudMailboxDocumentError: Error, Equatable { case notTheWriter, unreadable }

/// Reply-key-signed wrapper for a computer's `UpdateMailbox` stored in iCloud (`mailbox-*`),
/// so CloudKit cannot forge or redirect a computer's update mailbox without an enrolled device's signature.
public enum CloudMailboxDocument {

    enum RecordOutcome: Sendable, Equatable {
        case accepted(Agentkeyring_V2_UpdateMailbox)
        case retry
        case ignore
    }

    private static let domainV2 = "agentkeyring.cloud-mailbox.v2"

    public static func signedMailboxDocument(_ mailbox: Agentkeyring_V2_UpdateMailbox, signer: PayloadReplySigner) throws -> SignedDocument {
        var announcement = Agentkeyring_V2_CloudMailboxAnnouncement()
        announcement.domain = domainV2
        announcement.mailbox = mailbox
        return try CredentialSealing.signedDocument(announcement.serializedData(), by: signer.keyID, sign: signer.sign)
    }

    public static func opened(_ document: SignedDocument, writer: String, members: Members) throws -> Agentkeyring_V2_UpdateMailbox {
        let signer = try CredentialSealing.verifySignedDocument(document, members: members, allowReplyKey: true)
        guard signer.keyID == writer else { throw CloudMailboxDocumentError.notTheWriter }
        if let announcement = try? Agentkeyring_V2_CloudMailboxAnnouncement(serializedBytes: document.payload),
           announcement.domain == domainV2,
           announcement.hasMailbox {
            return announcement.mailbox
        }
        throw CloudMailboxDocumentError.unreadable
    }

    /// Decrypts, verifies, and validates an iCloud `mailbox-*` record against `members`.
    static func openRecord(
        _ record: CloudRecord,
        deviceID: String,
        members: Members,
        opener: CloudEnvelope.KeyOpener
    ) -> RecordOutcome {
        guard let opened = CloudEnvelope.openCloudEnvelope(record.payload, expectedKind: record.kind, deviceID: deviceID, opener: opener) else {
            return .retry
        }
        guard let signed = try? SignedDocument(serializedBytes: opened.plaintext),
              let mailbox = try? Self.opened(signed, writer: record.writer, members: members),
              record.kind == CloudRecordKind.mailbox(mailbox.machineID),
              members.machines.contains(where: { $0.machineID == mailbox.machineID }) else {
            return .ignore
        }
        return .accepted(mailbox)
    }
}

/// Caches the most recent `CloudEnvelope` per record name keyed by a hash of plaintext +
/// recipient public keys so `CloudVault.writeCloudRecords` skips uploading unchanged encrypted records.
public struct CloudSealCache: Sendable {
    private var entries: [String: (fingerprint: Data, sealed: Data)] = [:]

    public init() {}

    /// Seals for every Mac and iPhone in the signed list.
    public mutating func sealForMembers(
        name: String,
        kind: String,
        plaintext: Data,
        recipients: [String: P256.KeyAgreement.PublicKey],
        members: Members
    ) throws -> Data {
        let memberIDs = CloudEnvelope.memberDeviceIDs(in: members)
        for device in members.devices where memberIDs.contains(device.keyID) {
            guard let key = recipients[device.keyID], key.x963Representation == device.noticePublicKey else {
                throw CloudEnvelopeError.missingRecipientKey
            }
        }
        let activeRecipients = recipients.filter { memberIDs.contains($0.key) }
        return try seal(name: name, kind: kind, plaintext: plaintext, recipients: activeRecipients)
    }

    public mutating func seal(
        name: String,
        kind: String,
        plaintext: Data,
        recipients: [String: P256.KeyAgreement.PublicKey]
    ) throws -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(kind.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: plaintext)
        hasher.update(data: Data([0]))
        for id in recipients.keys.sorted() {
            hasher.update(data: Data(id.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: recipients[id]!.x963Representation)
            hasher.update(data: Data([0]))
        }
        let fingerprint = Data(hasher.finalize())
        if let cached = entries[name], cached.fingerprint == fingerprint {
            return cached.sealed
        }
        let sealed = try CloudEnvelope.seal(plaintext, kind: kind, recipients: recipients)
        entries[name] = (fingerprint, sealed)
        return sealed
    }
}
