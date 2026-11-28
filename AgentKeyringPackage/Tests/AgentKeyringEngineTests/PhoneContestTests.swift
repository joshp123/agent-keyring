// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The iPhone with no Mac awake: a Block it made offline, contested by the
// Mac's change of the same revision, is signed and sent from the iPhone alone,
// to iCloud and to every computer's update mailbox. And saved state it cannot
// decode starts first run again.

@testable import AgentKeyringEngine
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@MainActor
struct PhoneContestTests {
    /// How the iPhone settles the contest: Send Updates on Devices, or Block tapped again.
    enum Settle: CaseIterable { case sendUpdates, blockAgain }

    /// A joined iPhone with a Mac and a Linux computer in its list, all holding catalogue revision 1 with X on
    /// Ask First, and the computer's update mailbox at the test relay.
    @MainActor private struct Joined {
        let phone: PhoneKeyringEngine
        let keys: SoftwarePhoneKeys
        let phoneID: String
        let macID: String
        let members: Members
        let first: Catalogue
        let mailbox: Agentkeyring_V2_UpdateMailbox
        let pipe: InMemoryCloudPipe
        let macSign: (Catalogue) throws -> Data

        /// The Mac's revision 2, X Automatic, written to iCloud before the iPhone pulls it.
        func macWritesAutomatic() async throws {
            var automatic = first
            automatic.revision = 2
            automatic.logins[0].rule = .automatic
            automatic.logins[0].ruleUpdatedUnixMs = 9_000
            let sealed = try CloudEnvelope.seal(try macSign(automatic), kind: CloudRecordKind.catalogue,
                                                recipients: CloudEnvelope.recipients(for: members))
            try await pipe.writeCloudRecords([CloudRecord(kind: CloudRecordKind.catalogue, writer: macID, payload: sealed)])
        }

        /// iCloud's catalogue, opened by this iPhone.
        func shared() throws -> Data {
            let record = try #require(pipe.records[CloudRecordKind.catalogue])
            return try #require(CloudEnvelope.openCloudEnvelope(record.payload, expectedKind: CloudRecordKind.catalogue, deviceID: phoneID,
                                                   opener: try keys.cloudKeyOpener())).plaintext
        }
    }

    private func joined(in folder: URL) async throws -> Joined {
        let keys = SoftwarePhoneKeys()
        let phoneID = try CredentialSealing.keyID(keys.signingPublicKey())
        let mac = P256.Signing.PrivateKey()
        let macID = CredentialSealing.keyID(mac.publicKey.x963Representation)
        func macSigned(_ catalogue: Catalogue) throws -> Data {
            try CredentialSealing.signedDocument(catalogue.serializedData(), by: macID) { try mac.signature(for: $0).derRepresentation }.serializedData()
        }

        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.kind = .iphone
        phoneDevice.keyID = phoneID
        phoneDevice.signingPublicKey = try keys.signingPublicKey()
        phoneDevice.noticePublicKey = try keys.noticePublicKey()
        phoneDevice.openingPublicKey = try keys.openingPublicKey()
        phoneDevice.replyPublicKey = try keys.replyPublicKey()
        phoneDevice.replyKeyID = CredentialSealing.keyID(try keys.replyPublicKey())
        var macDevice = Agentkeyring_V2_Device()
        macDevice.kind = .mac
        macDevice.keyID = macID
        macDevice.signingPublicKey = mac.publicKey.x963Representation
        macDevice.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        var computer = Agentkeyring_V2_Machine()
        computer.machineID = "linux"
        computer.label = "Linux"
        computer.tlsPublicKey = P256.Signing.PrivateKey().publicKey.derRepresentation
        computer.receivingPublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [phoneDevice, macDevice]
        members.machines = [computer]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: phoneID) { try keys.signWithDeviceKey($0, context: LAContext()) }

        var x = Agentkeyring_V2_Login()
        x.loginID = "x"
        x.title = "Shop"
        x.rule = .ask
        x.version = 1
        x.ruleUpdatedUnixMs = 1_000
        x.ruleActor = macID
        var first = Catalogue()
        first.domain = "agentkeyring.catalogue.v2"
        first.revision = 1
        first.logins = [x]
        let mailbox = UpdateMailboxWriter.makeUpdateMailbox(for: computer.machineID, at: .configured)

        var saved = PhoneSavedState()
        saved.deviceKeyID = phoneID
        saved.firstRun = .finished
        saved.adoptMembers(members, signed: try signedMembers.serializedData())
        saved.signCatalogue(try macSigned(first))
        saved.mailboxes = [computer.machineID: try mailbox.serializedData()]
        try saved.encodeProtobuf().write(to: folder.appending(path: "phone-v2.pb"))
        let pipe = InMemoryCloudPipe()
        let phone = PhoneKeyringEngine(directory: folder, shared: PhoneSharedContext(accessGroup: nil), keys: keys,
                                 identity: { try DeviceTLSIdentity.ephemeral() }, cloud: pipe)
        await phone.cloudSync.pushCloudNow()
        return Joined(phone: phone, keys: keys, phoneID: phoneID, macID: macID, members: members, first: first, mailbox: mailbox, pipe: pipe,
                      macSign: macSigned)
    }

    @Test("A contested Block is signed and sent from the iPhone with the Mac's lid shut", arguments: Settle.allCases)
    func iPhoneSettlesTheContest(by settle: Settle) async throws {
        MemoryRelay.install()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let joined = try await joined(in: folder)
        let (phone, phoneID, mailbox, pipe) = (joined.phone, joined.phoneID, joined.mailbox, joined.pipe)
        defer { phone.stopBackgroundWork() }
        // Offline, the iPhone Blocks X at revision 2. The Mac makes it Automatic at revision 2 too, writes it to
        // iCloud, and shuts its lid.
        pipe.setAvailability(.unavailable("offline"))
        try await phone.setLoginRule(.blocked, forLogin: "x")
        pipe.setAvailability(.available)
        try await joined.macWritesAutomatic()
        await phone.cloudSync.pullCloudNow()
        #expect(phone.snapshot.hasUnsentUpdates)
        #expect(phone.catalogue?.logins.first?.rule == .blocked)

        switch settle {
        case .sendUpdates: try await phone.sendUnsentChanges()
        case .blockAgain: try await phone.setLoginRule(.blocked, forLogin: "x")
        }
        #expect(!phone.snapshot.hasUnsentUpdates)
        let held = try #require(phone.catalogue)
        #expect(held.revision == 3 && held.logins.first?.rule == .blocked)
        #expect(try joined.shared() == phone.state.catalogue)

        // The computer's mailbox now carries the Block, signed by the iPhone.
        await phone.cloudSync.mailboxes.writeMailboxSlots(olderThan: nil)
        let picked = try #require(try await RelayBoxClient.configured.fetchRelayBox(box: RelayBoxProtocol.mailboxSlot(seed: mailbox.seed, deviceKeyID: phoneID),
                                                                     key: RelayBoxProtocol.mailboxKey(seed: mailbox.seed), readAuth: mailbox.readAuth))
        let bundle = try Agentkeyring_V2_Bundle(serializedBytes: picked.message)
        #expect(bundle.catalogue.signerKeyID == phoneID)
        let sent = try Catalogue(serializedBytes: bundle.catalogue.payload)
        #expect(sent.revision == 3 && sent.logins.first?.rule == .blocked)
    }

    @Test("A Block made offline and written to iCloud by the background retry reaches the computers' mailboxes")
    func offlineBlockReachesMailboxesAfterBackgroundRetry() async throws {
        MemoryRelay.install()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let joined = try await joined(in: folder)
        let (phone, phoneID, mailbox, pipe) = (joined.phone, joined.phoneID, joined.mailbox, joined.pipe)
        defer { phone.stopBackgroundWork() }
        pipe.setAvailability(.unavailable("offline"))
        try await phone.setLoginRule(.blocked, forLogin: "x")
        #expect(phone.cloudSync.listsHeldFromComputers)

        pipe.setAvailability(.available)
        await phone.cloudSync.pushCloudNow()
        #expect(try joined.shared() == phone.state.catalogue)
        #expect(!phone.cloudSync.listsHeldFromComputers)

        await phone.cloudSync.mailboxes.writeMailboxSlots(olderThan: nil)
        let picked = try #require(try await RelayBoxClient.configured.fetchRelayBox(box: RelayBoxProtocol.mailboxSlot(seed: mailbox.seed, deviceKeyID: phoneID),
                                                                     key: RelayBoxProtocol.mailboxKey(seed: mailbox.seed), readAuth: mailbox.readAuth))
        let sent = try Catalogue(serializedBytes: Agentkeyring_V2_Bundle(serializedBytes: picked.message).catalogue.payload)
        #expect(sent.logins.first?.rule == .blocked)
    }

    @Test("A Block that loses iCloud's race to the Mac is signed again on top of it, under the same Face ID")
    func lostRaceIsSignedAgainInTheSameSession() async throws {
        MemoryRelay.install()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let joined = try await joined(in: folder)
        defer { joined.phone.stopBackgroundWork() }
        // The Mac's revision 2 reaches iCloud first; the iPhone, online, has not pulled it.
        try await joined.macWritesAutomatic()
        try await joined.phone.setLoginRule(.blocked, forLogin: "x")
        let held = try #require(joined.phone.catalogue)
        #expect(held.revision == 3 && held.logins.first?.rule == .blocked)
        #expect(!joined.phone.state.catalogueContested)
        #expect(try joined.shared() == joined.phone.state.catalogue)
    }

    @Test("A phone-v2.pb that cannot be decoded is replaced at launch, and first run sets this iPhone up again")
    func undecodableStateStartsAgain() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "phone-v2.pb")
        let junk = PhoneSavedState.protobufMagic + Data([0xFF, 0xFF, 0xFF, 0x0F])
        try junk.write(to: file)
        #expect(throws: (any Error).self) { try PhoneSavedState.decodeProtobuf(junk) }

        let phone = PhoneKeyringEngine(directory: folder, shared: PhoneSharedContext(accessGroup: nil), keys: SoftwarePhoneKeys(),
                                 identity: { try DeviceTLSIdentity.ephemeral() }, cloud: nil)
        defer { phone.stopBackgroundWork() }
        #expect(!phone.stateFileLocked)
        #expect(phone.firstRun == .start)
        phone.startBackgroundWork()
        await phone.sendFirstRunEvent(.continueTapped)
        try await phone.setUpHere()
        #expect(phone.state.deviceKeyID != nil)
        #expect(try PhoneSavedState.decodeProtobuf(Data(contentsOf: file)).deviceKeyID == phone.state.deviceKeyID)
    }

    @Test("A failed iPhone state write leaves the previous state in memory")
    func phoneSaveFailure() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: NoKeys(),
                                       identity: { throw CancellationError() })
        var initial = PhoneSavedState()
        initial.pushSeen = true
        try #require(phone.save(initial))

        // An atomic write cannot replace a nonempty directory with a file.
        try FileManager.default.moveItem(at: phone.stateURL, to: directory.appending(path: "previous.pb"))
        try FileManager.default.createDirectory(at: phone.stateURL, withIntermediateDirectories: false)
        try Data([1]).write(to: phone.stateURL.appending(path: "occupant"))
        var next = initial
        next.pushSeen = false

        #expect(!phone.save(next))
        #expect(phone.state == initial)
    }
}
