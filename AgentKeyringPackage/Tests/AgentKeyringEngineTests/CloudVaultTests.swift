// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// Josh exports on his iPhone; the Mac reads the iPhone's vault from iCloud.
// The Mac lists the iPhone's passwords, never takes a rule from a vault, and
// refuses a vault another key signed.

import AgentKeyringApprovalUI
@testable import AgentKeyringEngine
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import Testing

@Suite("Equal peers through iCloud")
struct CloudVaultTests {
    private static func device(_ kind: Agentkeyring_V2_DeviceKind, reply: P256.Signing.PrivateKey) -> Agentkeyring_V2_Device {
        var device = Agentkeyring_V2_Device()
        device.kind = kind
        device.signingPublicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        device.keyID = CredentialSealing.keyID(device.signingPublicKey)
        device.replyPublicKey = reply.publicKey.x963Representation
        device.replyKeyID = CredentialSealing.keyID(device.replyPublicKey)
        if kind != .watch { device.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation }
        return device
    }

    private static func signer(_ key: P256.Signing.PrivateKey) -> PayloadReplySigner {
        PayloadReplySigner(keyID: CredentialSealing.keyID(key.publicKey.x963Representation)) { try key.signature(for: $0).derRepresentation }
    }

    @Test("The Mac lists a password exported on the iPhone, and leaves the iPhone's vault's rules behind")
    func macFoldsTheIPhonesVault() throws {
        let phoneReply = P256.Signing.PrivateKey()
        let phone = Self.device(.iphone, reply: phoneReply)
        let mac = Self.device(.mac, reply: P256.Signing.PrivateKey())
        var members = Agentkeyring_V2_Members()
        members.devices = [mac, phone]
        let item = exportedItem(site: "shop.example", user: "josh", created: 538_768_074.380_438).stamped(by: phone.keyID, at: 200)
        let exported = CredentialVault(items: [item.id: item], rules: [item.id: LoginRuleTimestampEntry(.automatic, updatedAtMs: 9_000, actor: phone.keyID)])

        let inICloud = try VaultDocument.signedVaultDocument(exported, signer: Self.signer(phoneReply))
        let opened = try VaultDocument.opened(inICloud, writer: phone.keyID, members: members)
        #expect(opened.rules.isEmpty)
        let macList = StoredVaultSnapshot(id: UUID(), previousSnapshotID: nil, createdAt: .now, sourceExportedAt: .now, scope: .full,
            exporterIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords", items: [], skippedCredentialCount: 0)
        #expect(macList.folding(opened).items.map(\.id) == [item.id])

        let forged = try VaultDocument.signedVaultDocument(exported, signer: Self.signer(P256.Signing.PrivateKey()))
        #expect(throws: (any Error).self) { try VaultDocument.opened(forged, writer: phone.keyID, members: members) }
        #expect(throws: (any Error).self) { try VaultDocument.opened(inICloud, writer: mac.keyID, members: members) }
    }

    @Test("A new Mac joins the list on his iPhone only from a revision that iPhone signed naming this Mac")
    @MainActor
    func newMacJoinsTheIPhonesList() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akr-join-iphone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "MacBook Pro")
        func mac() -> MacSyncCoordinator {
            MacSyncCoordinator(keys: keys, store: MacVaultFileStore(directory: folder.appending(path: UUID().uuidString)),
                      leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: UUID().uuidString))),
                      environment: MacSyncEnvironment(storage: .memory())) { [] }
        }
        let phoneKey = P256.Signing.PrivateKey()
        var phone = Self.device(.iphone, reply: P256.Signing.PrivateKey())
        phone.signingPublicKey = phoneKey.publicKey.x963Representation
        phone.keyID = CredentialSealing.keyID(phone.signingPublicKey)
        func signed(_ devices: [Agentkeyring_V2_Device], revision: UInt64, by key: P256.Signing.PrivateKey) throws -> Data {
            var members = Agentkeyring_V2_Members()
            members.domain = "agentkeyring.members.v2"
            members.revision = revision
            members.devices = devices
            if devices.contains(where: { $0.keyID == keys.deviceKeyID }) { members.machines = [keys.machine] }
            return try CredentialSealing.signedDocument(members.serializedData(), by: CredentialSealing.keyID(key.publicKey.x963Representation)) {
                try key.signature(for: $0).derRepresentation
            }.serializedData()
        }
        let first = try signed([phone], revision: 1, by: phoneKey)
        for invalidKey in [Data(), Data([1, 2, 3])] {
            var invalidPhone = phone
            invalidPhone.noticePublicKey = invalidKey
            let document = try SignedDocument(serializedBytes: signed([invalidPhone], revision: 1, by: phoneKey))
            #expect(throws: CredentialSealingError.invalidNoticeKey) {
                try CredentialSealing.verifySignedMembers(document, current: nil)
            }
        }

        let alone = try CloudMembers.payload(current: first, history: [first])
        let strangerKey = P256.Signing.PrivateKey()
        var stranger = phone
        stranger.signingPublicKey = strangerKey.publicKey.x963Representation
        stranger.keyID = CredentialSealing.keyID(stranger.signingPublicKey)
        let forged = try CloudMembers.payload(current: try signed([stranger, keys.device], revision: 2, by: strangerKey), history: [])
        let refusing = mac()
        #expect(await refusing.adoptIPhoneList(alone, inviter: phone.keyID) == false)
        #expect(await refusing.adoptIPhoneList(forged, inviter: phone.keyID) == false)
        #expect(refusing.members == nil)

        let added = try CloudMembers.payload(current: try signed([phone, keys.device], revision: 2, by: phoneKey), history: [first])
        let joining = mac()
        #expect(await joining.adoptIPhoneList(added, inviter: phone.keyID))
        #expect(joining.members?.devices.map(\.keyID) == [phone.keyID, keys.deviceKeyID])
        #expect(joining.members?.machines.map(\.machineID) == [keys.machineID])
    }

    @Test("A device writes its list of devices over iCloud's only when iCloud's is an older one of the same keyring, or not a real list")
    func listOfDevicesInICloud() throws {
        func device(_ kind: Agentkeyring_V2_DeviceKind) -> (Agentkeyring_V2_Device, P256.Signing.PrivateKey) {
            let key = P256.Signing.PrivateKey()
            var device = Self.device(kind, reply: P256.Signing.PrivateKey())
            device.signingPublicKey = key.publicKey.x963Representation
            device.keyID = CredentialSealing.keyID(device.signingPublicKey)
            return (device, key)
        }
        func signed(_ devices: [Agentkeyring_V2_Device], revision: UInt64, by key: P256.Signing.PrivateKey) throws -> Data {
            var members = Agentkeyring_V2_Members()
            members.domain = "agentkeyring.members.v2"
            members.revision = revision
            members.devices = devices
            return try CredentialSealing.signedDocument(members.serializedData(), by: CredentialSealing.keyID(key.publicKey.x963Representation)) {
                try key.signature(for: $0).derRepresentation
            }.serializedData()
        }
        func list(_ bytes: Data) throws -> Agentkeyring_V2_Members {
            try Agentkeyring_V2_Members(serializedBytes: SignedDocument(serializedBytes: bytes).payload)
        }
        let (mac, macKey) = device(.mac)
        let (phone, phoneKey) = device(.iphone)

        // The iPhone signed revision 2 and was then lost; the Mac removed it in revision 3.
        let first = try signed([mac, phone], revision: 1, by: macKey)
        let byPhone = try signed([mac, phone], revision: 2, by: phoneKey)
        let removal = try signed([mac], revision: 3, by: macKey)
        let held = [first, byPhone, removal]
        let inICloud = try CloudMembers.payload(current: byPhone, history: [first])
        #expect(CloudMembers.mayReplace(inICloud, with: 3, members: try list(removal), history: held))

        // Another keyring, set up on its own, is never written over by this one.
        let (stranger, strangerKey) = device(.iphone)
        let another = try CloudMembers.payload(current: try signed([stranger], revision: 1, by: strangerKey), history: [])
        #expect(!CloudMembers.mayReplace(another, with: 3, members: try list(removal), history: held))
        #expect(CloudMembers.isAnotherKeyring(another, members: try list(removal), history: held))

        // A later list of this keyring, signed by a device added since, stays; one that is no real list does not.
        let (added, addedKey) = device(.mac)
        let withAdded = try signed([mac, phone, added], revision: 3, by: phoneKey)
        let byAdded = try signed([mac, phone, added], revision: 4, by: addedKey)
        let later = try CloudMembers.payload(current: byAdded, history: [first, byPhone, withAdded])
        let offline = try signed([mac, phone], revision: 3, by: macKey)
        #expect(!CloudMembers.mayReplace(later, with: 3, members: try list(offline), history: [first, byPhone, offline]))
        let forged = try CloudMembers.payload(current: try signed([mac], revision: 99, by: strangerKey), history: [])
        #expect(CloudMembers.mayReplace(forged, with: 3, members: try list(removal), history: held))

        // A lower-revision forked branch that removed the writer is never overwritten; a trailing forged
        // entry on top of our own valid base never blocks an atomic removal.
        let revokedMacRev2 = try signed([phone], revision: 2, by: phoneKey)
        let forkedRev2 = try CloudMembers.payload(current: revokedMacRev2, history: [first])
        #expect(!CloudMembers.mayReplace(forkedRev2, with: 3, members: try list(removal), history: held))
        #expect(!CloudMembers.mayReplaceBase(forkedRev2, base: removal, members: try list(removal), history: held))
        let baseWithTrailingForgery = try CloudMembers.payload(
            current: try signed([mac], revision: 99, by: strangerKey),
            history: [first, byPhone, removal]
        )
        #expect(CloudMembers.mayReplaceBase(baseWithTrailingForgery, base: removal, members: try list(removal), history: held))
    }

    @Test("A password exported on another device keeps that device's version until this one holds a copy; Blocked lists none")
    func catalogueKeepsAnotherDevicesVersion() {
        let item = exportedItem(site: "shop.example", user: "josh", created: 538_768_074.380_438).stamped(by: "iphone", at: 200)
        let vault = CredentialVault(items: [item.id: item])
        var listed = Agentkeyring_V2_Login()
        listed.loginID = item.id.uuidString
        listed.version = 200
        var previous = Agentkeyring_V2_Catalogue()
        previous.logins = [listed]
        #expect(vault.catalogueLogins(rules: [:], fresh: [:], previous: previous).first?.version == 200)
        let blocked = [item.id: LoginRuleTimestampEntry(.blocked, updatedAtMs: 1, actor: "mac")]
        #expect(vault.catalogueLogins(rules: blocked, fresh: [:], previous: previous).first?.version == 0)
    }

    @Test("Switching a password from Automatic to Ask on the iPhone drops the computer's copy; Apple Watch keeps its own")
    func automaticToAskDropsTheComputersCopy() {
        var computer = Agentkeyring_V2_Machine()
        computer.machineID = "mac-mini"
        var watch = Agentkeyring_V2_Device()
        watch.keyID = "watch"
        watch.kind = .watch
        var members = Agentkeyring_V2_Members()
        members.devices = [watch]
        members.machines = [computer]
        var login = Agentkeyring_V2_Login()
        login.loginID = "shop"
        login.version = 200
        login.rule = .automatic
        var catalogue = Agentkeyring_V2_Catalogue()
        catalogue.logins = [login]
        func copy(for opener: String) -> SealedLogin {
            var copy = SealedLogin()
            copy.loginID = "shop"
            copy.version = 200
            copy.openerID = opener
            return copy
        }
        let made = [copy(for: "mac-mini"), copy(for: "watch"), copy(for: "removed-watch")]
        #expect(PhoneKeyringEngine.current(made, catalogue: catalogue, members: members).map(\.openerID) == ["mac-mini", "watch"])
        catalogue.logins[0].rule = .ask
        #expect(PhoneKeyringEngine.current(made, catalogue: catalogue, members: members).map(\.openerID) == ["watch"])
    }

    @Test("Cloud metadata (catalogue, vault, mailbox) is end-to-end encrypted to enrolled devices so iCloud sees only ciphertext")
    func cloudMetadataEncryptedForEnrolledDevicesOnly() throws {
        let macNotice = P256.KeyAgreement.PrivateKey()
        let phoneNotice = P256.KeyAgreement.PrivateKey()
        let removedNotice = P256.KeyAgreement.PrivateKey()
        let macReply = P256.Signing.PrivateKey()
        let phoneReply = P256.Signing.PrivateKey()

        var mac = Self.device(.mac, reply: macReply)
        mac.noticePublicKey = macNotice.publicKey.x963Representation
        var phone = Self.device(.iphone, reply: phoneReply)
        phone.noticePublicKey = phoneNotice.publicKey.x963Representation
        var watch = Self.device(.watch, reply: P256.Signing.PrivateKey())
        watch.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        var removed = Self.device(.iphone, reply: P256.Signing.PrivateKey())
        removed.noticePublicKey = removedNotice.publicKey.x963Representation

        var members = Agentkeyring_V2_Members()
        members.devices = [mac, phone, watch]

        let recipients = CloudEnvelope.recipients(for: members)
        #expect(Set(recipients.keys) == [mac.keyID, phone.keyID])

        let secretSite = "private-bank.example"
        let secretUser = "josh-secret-user"
        let item = exportedItem(site: secretSite, user: secretUser, created: 538_768_074.380_438).stamped(by: mac.keyID, at: 200)
        let vaultDoc = try VaultDocument.signedVaultDocument(CredentialVault(items: [item.id: item]), signer: Self.signer(macReply)).serializedData()

        let kind = CloudRecordKind.vault(mac.keyID)
        var cache = CloudSealCache()
        let sealed = try cache.sealForMembers(name: kind, kind: kind, plaintext: vaultDoc, recipients: recipients, members: members)
        #expect(sealed.prefix(8) == Data("AKRCLD02".utf8))
        #expect(CloudEnvelope.isSealed(sealed))
        #expect(sealed.range(of: Data(secretSite.utf8)) == nil)
        #expect(sealed.range(of: Data(secretUser.utf8)) == nil)

        func opener(_ key: P256.KeyAgreement.PrivateKey) -> CloudEnvelope.KeyOpener {
            { try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: key) }
        }

        let macOpened = try #require(CloudEnvelope.openCloudEnvelope(sealed, expectedKind: kind, deviceID: mac.keyID, opener: opener(macNotice)))
        #expect(macOpened.plaintext == vaultDoc)
        #expect(macOpened.recipientIDs == [mac.keyID, phone.keyID])

        let phoneOpened = try #require(CloudEnvelope.openCloudEnvelope(sealed, expectedKind: kind, deviceID: phone.keyID, opener: opener(phoneNotice)))
        #expect(phoneOpened.plaintext == vaultDoc)
        #expect(phoneOpened.recipientIDs == [mac.keyID, phone.keyID])

        #expect(CloudEnvelope.openCloudEnvelope(sealed, expectedKind: kind, deviceID: removed.keyID, opener: opener(removedNotice)) == nil)

        #expect(CloudEnvelope.openCloudEnvelope(sealed, expectedKind: CloudRecordKind.catalogue, deviceID: phone.keyID, opener: opener(phoneNotice)) == nil)

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        #expect(CloudEnvelope.openCloudEnvelope(tampered, expectedKind: kind, deviceID: phone.keyID, opener: opener(phoneNotice)) == nil)

        #expect(CloudEnvelope.openCloudEnvelope(vaultDoc, expectedKind: kind, deviceID: phone.keyID, opener: opener(phoneNotice)) == nil)

        #expect(!CloudEnvelope.needsReseal(existingRecipientKeys: macOpened.recipientKeyFingerprints, expectedRecipients: recipients, memberDevices: [mac.keyID, phone.keyID]))
        #expect(CloudEnvelope.needsReseal(existingRecipientKeys: macOpened.recipientKeyFingerprints, expectedRecipients: [mac.keyID: macNotice.publicKey], memberDevices: [mac.keyID]))
        let rotatedPhone = P256.KeyAgreement.PrivateKey()
        let withRotated = [mac.keyID: macNotice.publicKey, phone.keyID: rotatedPhone.publicKey]
        #expect(CloudEnvelope.needsReseal(existingRecipientKeys: macOpened.recipientKeyFingerprints, expectedRecipients: withRotated, memberDevices: [mac.keyID, phone.keyID]))

        var invalidMembers = members
        for invalidKey in [Data(), Data([1, 2, 3])] {
            invalidMembers.devices[1].noticePublicKey = invalidKey
            #expect(throws: CloudEnvelopeError.missingRecipientKey) {
                try cache.sealForMembers(name: kind, kind: kind, plaintext: vaultDoc,
                                  recipients: CloudEnvelope.recipients(for: invalidMembers), members: invalidMembers)
            }
        }

        let mailbox = UpdateMailboxWriter.makeUpdateMailbox(for: "machine-1", at: .configured)
        let signedMailbox = try CloudMailboxDocument.signedMailboxDocument(mailbox, signer: Self.signer(macReply))
        let announcement = try Agentkeyring_V2_CloudMailboxAnnouncement(serializedBytes: signedMailbox.payload)
        #expect(announcement.domain == "agentkeyring.cloud-mailbox.v2")
        #expect(announcement.mailbox == mailbox)
        #expect(try CloudMailboxDocument.opened(signedMailbox, writer: mac.keyID, members: members) == mailbox)
        #expect(throws: (any Error).self) { try CloudMailboxDocument.opened(signedMailbox, writer: phone.keyID, members: members) }
        let forgedMailbox = try CloudMailboxDocument.signedMailboxDocument(mailbox, signer: Self.signer(P256.Signing.PrivateKey()))
        #expect(throws: (any Error).self) { try CloudMailboxDocument.opened(forgedMailbox, writer: mac.keyID, members: members) }
    }

    @Test("CloudSealCache reuses ciphertext for unchanged plaintext and recipients")
    func cloudSealCache() throws {
        let recipients = ["mac": P256.KeyAgreement.PrivateKey().publicKey]
        var cache = CloudSealCache()
        let first = try cache.seal(name: CloudRecordKind.catalogue, kind: CloudRecordKind.catalogue, plaintext: Data("v1".utf8), recipients: recipients)
        let second = try cache.seal(name: CloudRecordKind.catalogue, kind: CloudRecordKind.catalogue, plaintext: Data("v1".utf8), recipients: recipients)
        let third = try cache.seal(name: CloudRecordKind.catalogue, kind: CloudRecordKind.catalogue, plaintext: Data("v2".utf8), recipients: recipients)
        #expect(first == second)
        #expect(first != third)
    }

    @Test("JoinProof binds Device.noticePublicKey when set and rejects tampering or stripping")
    func joinProofBindsNoticePublicKey() {
        let secret = Data(repeating: 7, count: 32)
        var device = Self.device(.iphone, reply: P256.Signing.PrivateKey())
        device.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        var request = Agentkeyring_V2_JoinRequest()
        request.device = device
        let proof = CredentialSealing.joinProof(secret: secret, joining: request)

        // Stripping noticePublicKey breaks the proof.
        var stripped = request
        stripped.device.noticePublicKey = Data()
        #expect(CredentialSealing.joinProof(secret: secret, joining: stripped) != proof)

        // Substituting an attacker's noticePublicKey breaks the proof.
        var swapped = request
        swapped.device.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        #expect(CredentialSealing.joinProof(secret: secret, joining: swapped) != proof)
    }

    @Test("Same-second push registrations converge in either arrival order")
    func sameSecondPushRegistrationConvergence() throws {
        let reply = P256.Signing.PrivateKey()
        let device = Self.device(.mac, reply: reply)
        var members = Members()
        members.devices = [device]
        var first = Agentkeyring_V2_PushRegistration()
        first.domain = "agentkeyring.push.v2"
        first.deviceKeyID = device.keyID
        first.apnsToken = Data([1])
        first.apnsTopic = "com.example.keyring"
        first.noticePublicKey = device.noticePublicKey
        first.registeredUnixSeconds = 100
        var second = first
        second.apnsToken = Data([2])
        let signer = Self.signer(reply)
        let a = try CredentialSealing.signedDocument(first.serializedData(), by: signer.keyID, sign: signer.sign).serializedData()
        let b = try CredentialSealing.signedDocument(second.serializedData(), by: signer.keyID, sign: signer.sign).serializedData()

        func receive(_ documents: [Data]) throws -> Data? {
            try documents.reduce(nil) { stored, bytes in
                let registration = try CloudPushRegistration.verified(bytes, members: members).registration
                return CloudPushRegistration.isNewer(registration, than: stored) ? bytes : stored
            }
        }
        #expect(try receive([a, b]) == b)
        #expect(try receive([b, a]) == b)
        #expect(!CloudPushRegistration.isNewer(second, than: b))
        first.registeredUnixSeconds += 1
        #expect(CloudPushRegistration.isNewer(first, than: b))
    }

    @Test("CloudVault.batch handles 0-byte payloads without crashing")
    func cloudVaultBatchZeroBytePayload() {
        let empty = CloudRecord(kind: "empty", writer: "mac", payload: Data())
        let small = CloudRecord(kind: "small", writer: "mac", payload: Data([1, 2, 3]))
        let batches = CloudVault.batch([empty, small], maxBatchBytes: 100)
        #expect(batches.count == 1)
        #expect(batches[0].map(\.name) == ["empty", "small"])

        let onlyEmpty = CloudVault.batch([empty], maxBatchBytes: 100)
        #expect(onlyEmpty.count == 1)
        #expect(onlyEmpty[0].map(\.name) == ["empty"])
    }

    @Test("UpdateMailboxWriter.computerUpdateBundle omits freshness when closure returns nil")
    func mailboxesBundleNilFreshness() throws {
        let macReply = P256.Signing.PrivateKey()
        let macSigning = P256.Signing.PrivateKey()
        var mac = Self.device(.mac, reply: macReply)
        mac.signingPublicKey = macSigning.publicKey.x963Representation
        mac.keyID = CredentialSealing.keyID(mac.signingPublicKey)
        var computer = Agentkeyring_V2_Machine()
        computer.machineID = "machine-1"
        var members = Agentkeyring_V2_Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [mac]
        members.machines = [computer]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: mac.keyID) {
            try macSigning.signature(for: $0).derRepresentation
        }

        let withoutFreshness = UpdateMailboxWriter.computerUpdateBundle(
            for: computer.machineID,
            lists: MailboxSignedLists(members: signedMembers, membersHistory: [signedMembers], catalogue: nil,
                                      pushRegistrations: []),
            copies: []
        ) { nil }
        #expect(!withoutFreshness.hasFreshness)

        let withFreshness = UpdateMailboxWriter.computerUpdateBundle(
            for: computer.machineID,
            lists: MailboxSignedLists(members: signedMembers, membersHistory: [signedMembers], catalogue: nil,
                                      pushRegistrations: []),
            copies: []
        ) {
            try? UpdateMailboxWriter.signFreshness(for: computer.machineID, members: 1, catalogue: 0,
                                     signerKeyID: mac.replyKeyID, sign: Self.signer(macReply).sign)
        }
        #expect(withFreshness.hasFreshness)
        #expect(!withFreshness.freshness.signature.isEmpty)
    }

    @Test("CloudCatalogue, CloudPullGate, and PhoneNotification protobuf IPC")
    @MainActor
    func cloudSyncHelpersAndPhoneNotificationProto() async throws {
        let macSigning = P256.Signing.PrivateKey()
        let macNotice = P256.KeyAgreement.PrivateKey()
        var mac = Self.device(.mac, reply: P256.Signing.PrivateKey())
        mac.signingPublicKey = macSigning.publicKey.x963Representation
        mac.keyID = CredentialSealing.keyID(mac.signingPublicKey)
        mac.noticePublicKey = macNotice.publicKey.x963Representation

        var members = Agentkeyring_V2_Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [mac]

        func signedCat(_ rev: UInt64) throws -> Data {
            var cat = Agentkeyring_V2_Catalogue()
            cat.domain = "agentkeyring.catalogue.v2"
            cat.revision = rev
            return try CredentialSealing.signedDocument(cat.serializedData(), by: mac.keyID) {
                try macSigning.signature(for: $0).derRepresentation
            }.serializedData()
        }
        let cat1 = try signedCat(1)
        let cat2 = try signedCat(2)
        let opener: CloudEnvelope.KeyOpener = {
            try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: macNotice)
        }
        let recipients = [mac.keyID: macNotice.publicKey]
        let submittedCat2 = SubmittedCatalogue(signedBytes: cat2, recipients: recipients)
        let sealedCat1 = try CloudEnvelope.seal(cat1, kind: CloudRecordKind.catalogue, recipients: recipients)
        #expect(CloudCatalogue.shouldReplace(sealedCat1, with: submittedCat2, members: members, deviceID: mac.keyID,
                                             opener: opener))
        let sealedCat2 = try CloudEnvelope.seal(cat2, kind: CloudRecordKind.catalogue, recipients: recipients)
        #expect(!CloudCatalogue.shouldReplace(sealedCat2, with: submittedCat2, members: members, deviceID: mac.keyID,
                                             opener: opener))
        let formerRecipients = recipients.merging(["former": P256.KeyAgreement.PrivateKey().publicKey]) { current, _ in current }
        let staleSeal = try CloudEnvelope.seal(cat2, kind: CloudRecordKind.catalogue, recipients: formerRecipients)
        #expect(CloudCatalogue.shouldReplace(staleSeal, with: submittedCat2, members: members, deviceID: mac.keyID,
                                             opener: opener))

        // Monotonic LeaseState precedence: delayed approval cannot resurrect stopped/denied/cancelled
        #expect(Agentkeyring_V2_LeaseState.approved.canReplace(.waiting))
        #expect(Agentkeyring_V2_LeaseState.ended.canReplace(.approved))
        #expect(!Agentkeyring_V2_LeaseState.approved.canReplace(.ended))
        #expect(!Agentkeyring_V2_LeaseState.approved.canReplace(.denied))
        #expect(!Agentkeyring_V2_LeaseState.approved.canReplace(.cancelled))
        #expect(!Agentkeyring_V2_LeaseState.waiting.canReplace(.approved))

        // Cancelled CloudPullGate run must never resolve or clear a replacement run started while it was suspended
        let cancelGate = CloudPullGate()
        let firstPullTask = Task {
            await cancelGate.runPull {
                try? await Task.sleep(for: .milliseconds(40))
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        cancelGate.cancelPulls()
        let secondPullResult = await cancelGate.runPull {
            try? await Task.sleep(for: .milliseconds(70))
            return true
        }
        let firstPullResult = await firstPullTask.value
        #expect(!firstPullResult)
        #expect(secondPullResult)

        // CloudPullGate coalesces concurrent pulls into at most one trailing pass
        final class Counter: @unchecked Sendable {
            var runs = 0
        }
        let gate = CloudPullGate()
        let counter = Counter()
        async let first: Bool = gate.runPull {
            counter.runs += 1
            try? await Task.sleep(for: .milliseconds(30))
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
        async let second: Bool = gate.runPull {
            counter.runs += 1
            return true
        }
        gate.trigger {
            counter.runs += 1
            return true
        }
        let (r1, r2) = await (first, second)
        #expect(r1 && r2)
        #expect(counter.runs == 2)

        // PhoneNotification protobuf encode/decode
        let asked = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = Date(timeIntervalSince1970: 1_700_000_600)
        let req = AccessRequest(
            id: "req-proto-1",
            login: RequestedLogin(site: "github.com", account: "josh"),
            agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: "", folder: "/code", project: "agent-keyring"),
            access: .login,
            agentReason: "Push branch",
            askedAt: asked,
            state: .waitingForYou(until: deadline)
        )
        let encoded = PhoneNotification.encode(req, deadline: deadline)
        let decoded = try #require(PhoneNotification.decode([PhoneNotification.wordsKey: encoded]))
        #expect(decoded.id == "req-proto-1")
        #expect(decoded.login.site == "github.com")
        #expect(decoded.agent.project == "agent-keyring")
        #expect(decoded.agent.folder == "/code")
        #expect(PhoneNotification.requestID([PhoneNotification.wordsKey: encoded]) == "req-proto-1")
    }

    @Test("Local and cloud protobuf storage codecs round-trip")
    @MainActor
    func localAndCloudProtobufCodecs() throws {
        let itemID = UUID()
        let prevGenID = UUID()
        let genID = UUID()
        let deletedID = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_700_000_123.5)
        let stamp = LoginSecretRevisionStamp(revision: modified, version: 42, actor: "mac-1", exportedAt: created)
        let item = StoredVaultLogin(
            id: itemID,
            sourceIdentity: LoginSourceIdentity(
                exporterIdentifier: "com.apple.Passwords",
                accountID: Data([1, 2, 3]),
                itemID: Data([4, 5, 6])
            ),
            createdAt: created,
            lastModifiedAt: modified,
            title: "GitHub",
            subtitle: "work",
            isFavorite: true,
            origins: ["https://github.com"],
            credentials: [
                .password(userName: "josh", password: "secret"),
                .totp(secret: Data([9, 8, 7]), period: 30, digits: 6, userName: "josh", algorithm: .sha256, issuer: "GitHub"),
            ],
            imports: [stamp],
            secretsDeletedAt: 10
        )
        let emptyImportsItem = StoredVaultLogin(
            id: UUID(),
            sourceIdentity: LoginSourceIdentity(exporterIdentifier: "com.apple.Passwords", accountID: Data([1]), itemID: Data([2])),
            title: "EmptyImports",
            origins: [],
            credentials: [.password(userName: nil, password: "")],
            imports: []
        )
        let nilImportsItem = StoredVaultLogin(
            id: UUID(),
            sourceIdentity: LoginSourceIdentity(exporterIdentifier: "com.apple.Passwords", accountID: Data([1]), itemID: Data([3])),
            title: "NilImports",
            origins: [],
            credentials: [.password(userName: nil, password: "")],
            imports: nil
        )
        let generation = StoredVaultSnapshot(
            id: genID,
            previousSnapshotID: prevGenID,
            createdAt: created,
            sourceExportedAt: modified,
            scope: .selected,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: [item, emptyImportsItem, nilImportsItem],
            missingItemIDs: [deletedID],
            skippedCredentialCount: 3,
            skippedCredentialSummary: SkippedLoginImportSummary(passkeyCount: 1, missingPasswordCount: 1, otherCount: 1),
            deleted: [deletedID: created]
        )
        let genProtoBytes = try generation.encodeProtobuf()
        #expect(genProtoBytes.starts(with: Data("AKRGEN02".utf8)))
        let genDecoded = try StoredVaultSnapshot.decodeProtobuf(genProtoBytes)
        #expect(genDecoded == generation)
        #expect(genDecoded.items[1].imports == [])
        #expect(genDecoded.items[2].imports == nil)
        let vault = CredentialVault(
            items: [item.id: item],
            rules: [item.id: LoginRuleTimestampEntry(.automatic, updatedAtMs: 5_000, actor: "mac-1")],
            deleted: [deletedID: created]
        )
        let vaultProtoBytes = try vault.encodeProtobuf()
        #expect(vaultProtoBytes.starts(with: Data("AKRVLT02".utf8)))
        #expect(try CredentialVault.decodeProtobuf(vaultProtoBytes) == vault)

        let macReply = P256.Signing.PrivateKey()
        let mac = Self.device(.mac, reply: macReply)
        var members = Agentkeyring_V2_Members()
        members.devices = [mac]
        let signedDoc = try VaultDocument.signedVaultDocument(vault, signer: Self.signer(macReply))
        #expect(signedDoc.payload.starts(with: Data("AKRVLT02".utf8)))
        let openedDoc = try VaultDocument.opened(signedDoc, writer: mac.keyID, members: members)
        #expect(openedDoc.items == [item.id: item.redacted])
        #expect(openedDoc.rules.isEmpty)
        #expect(openedDoc.deleted == vault.deleted)

        var storedTLS: Data?
        let createdTLS = try DeviceTLSIdentity.loadOrCreate(read: { storedTLS }, write: { storedTLS = $0 })
        let writtenTLS = try #require(storedTLS)
        #expect(writtenTLS.starts(with: Data("AKRTLS02".utf8)))
        let reloadedTLS = try DeviceTLSIdentity.loadOrCreate(read: { storedTLS }, write: { _ in Issue.record("Should not rewrite") })
        #expect(reloadedTLS.publicKeySPKI == createdTLS.publicKeySPKI)

        var settings = NotificationSettings()
        settings.timeSensitive = false
        settings.quietHours = true
        settings.quietFrom = 22 * 60
        settings.quietTo = 6 * 60
        let snapshot = PhoneSharedSnapshot(
            deviceKeyID: "phone-1",
            members: Data([10, 20]),
            catalogue: Data([30, 40]),
            settings: settings
        )
        let ctxBytes = try PhoneSharedContext.encodeSnapshot(snapshot)
        #expect(ctxBytes.starts(with: Data("AKRCTX02".utf8)))
        let ctxDecoded = try #require(PhoneSharedContext.decodeSnapshot(ctxBytes))
        #expect(ctxDecoded.deviceKeyID == snapshot.deviceKeyID)
        #expect(ctxDecoded.members == snapshot.members)
        #expect(ctxDecoded.catalogue == snapshot.catalogue)
        #expect(ctxDecoded.settings == snapshot.settings)

        let emptySnapshot = PhoneSharedSnapshot()
        let emptyCtxBytes = try PhoneSharedContext.encodeSnapshot(emptySnapshot)
        let emptyCtxDecoded = try #require(PhoneSharedContext.decodeSnapshot(emptyCtxBytes))
        #expect(emptyCtxDecoded.deviceKeyID == nil)
        #expect(emptyCtxDecoded.members == nil)
        #expect(emptyCtxDecoded.catalogue == nil)
        #expect(emptyCtxDecoded.settings == nil)
    }
}
