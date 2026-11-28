// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The shared replica (AgentKeyringEngine/Cloud/KeyringReplica.swift) through its public API, with devices syncing
// through an InMemoryCloudPipe: two devices that signed the same catalogue revision apart, or an offline
// Block at one revision and two changes elsewhere at the next, end on the same list with Block kept (updated
// on 2026.11.27 by model claude opus 5.5), a pull whose save fails never moves the checkpoint, the Mac and the iPhone keep saved
// state they could not read instead of writing over it, a zone deleted from Settings is written again, and a
// second push token in the same second wins on every device.

@testable import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing

struct TestReplica: KeyringReplica {
    var members: Data?
    var membersHistory: [Data] = []
    var catalogue: Data?
    var contestedCatalogues: [Data] = []
    var pushRegistrations: [String: Data] = [:]
    var mailboxes: [String: Data] = [:]
    var cloudAcceptedMembers: Data?
    var cloudAcceptedCatalogue: Data?
    var cloudCheckpoint = CloudCheckpoint()
}

/// One approving device: its keys, and the lists it keeps.
struct Peer {
    let signing = P256.Signing.PrivateKey()
    let notice = P256.KeyAgreement.PrivateKey()
    let kind: Agentkeyring_V2_DeviceKind
    var replica = TestReplica()

    var id: String { CredentialSealing.keyID(signing.publicKey.x963Representation) }

    var device: Agentkeyring_V2_Device {
        var device = Agentkeyring_V2_Device()
        device.kind = kind
        device.signingPublicKey = signing.publicKey.x963Representation
        device.keyID = id
        device.noticePublicKey = notice.publicKey.x963Representation
        return device
    }

    var opener: CloudEnvelope.KeyOpener {
        let key = notice
        return { try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: key) }
    }

    func signed(_ payload: Data) throws -> Data {
        try CredentialSealing.signedDocument(payload, by: id) { try signing.signature(for: $0).derRepresentation }.serializedData()
    }

    func signed(_ catalogue: Catalogue) throws -> Data { try signed(catalogue.serializedData()) }
}

private func login(_ id: String, rule: Agentkeyring_V2_Rule, version: UInt64, at ms: Int64, by actor: String) -> Agentkeyring_V2_Login {
    var login = Agentkeyring_V2_Login()
    login.loginID = id
    login.title = id
    login.rule = rule
    login.version = version
    login.ruleUpdatedUnixMs = ms
    login.ruleActor = actor
    return login
}

func catalogue(_ revision: UInt64, _ logins: [Agentkeyring_V2_Login]) -> Catalogue {
    var catalogue = Catalogue()
    catalogue.domain = "agentkeyring.catalogue.v2"
    catalogue.revision = revision
    catalogue.logins = logins
    return catalogue
}

/// A device's push of its catalogue, as MacCloud and PhoneCloud do it: written unless iCloud's must stay, that one
/// taken in, and the device's own beside it while the two are contested.
private func push(_ peer: inout Peer, to pipe: InMemoryCloudPipe) async throws {
    let members = try #require(peer.replica.currentMembers)
    let own = try #require(peer.replica.catalogue)
    let recipients = CloudEnvelope.recipients(for: members)
    let opener = peer.opener
    let id = peer.id
    let sealed = try CloudEnvelope.seal(own, kind: CloudRecordKind.catalogue, recipients: recipients)
    if let theirs = try await pipe.writeCloudRecordIfNewer(CloudRecord(kind: CloudRecordKind.catalogue, writer: id, payload: sealed), isNewer: {
        CloudCatalogue.shouldReplace($0, with: SubmittedCatalogue(signedBytes: own, recipients: recipients),
                                     members: members, deviceID: id, opener: opener)
    }) {
        let opened = try #require(CloudEnvelope.openCloudEnvelope(theirs, expectedKind: CloudRecordKind.catalogue, deviceID: id, opener: opener))
        try peer.replica.intakeCatalogue(opened.plaintext, members: members)
    }
    if peer.replica.catalogueContested, let side = peer.replica.ownContestedCatalogue(signedBy: id) {
        let kind = CloudRecordKind.contested(id)
        try await pipe.writeCloudRecords([CloudRecord(kind: kind, writer: id, payload: try CloudEnvelope.seal(side, kind: kind, recipients: recipients))])
    }
}

/// A device's pull, as MacCloud and PhoneCloud do it: every catalogue another device wrote taken in, then the checkpoint.
private func pull(_ peer: inout Peer, from pipe: InMemoryCloudPipe) async throws {
    let members = try #require(peer.replica.currentMembers)
    let changes = try await pipe.fetchCloudChanges(since: peer.replica.cloudCheckpoint.changeToken)
    let round = ReplicaPull(changes, after: peer.replica.cloudCheckpoint)
    for record in round.records where record.writer != peer.id
        && (record.name == CloudRecordKind.catalogue || record.kind == CloudRecordKind.contested(record.writer)) {
        let opened = try #require(CloudEnvelope.openCloudEnvelope(record.payload, expectedKind: record.kind, deviceID: peer.id, opener: peer.opener))
        round.clearRecordRetry(record.name)
        try peer.replica.intakeCatalogue(opened.plaintext, members: members)
    }
    peer.replica.cloudCheckpoint = round.nextCheckpoint(readAllAgain: false)
}

@MainActor
struct ReplicaCoreTests {
    /// The Mac and the iPhone, listed in one Members at revision 1, both holding catalogue revision 1.
    private static func pair() throws -> (mac: Peer, phone: Peer, base: [Agentkeyring_V2_Login]) {
        var mac = Peer(kind: .mac)
        var phone = Peer(kind: .iphone)
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [mac.device, phone.device]
        let signedMembers = try mac.signed(members.serializedData())
        let base = [login("shop", rule: .ask, version: 1, at: 1_000, by: mac.id)]
        let first = try mac.signed(catalogue(1, base))
        for index in 0..<2 {
            var replica = TestReplica()
            replica.adoptMembers(members, signed: signedMembers)
            replica.signCatalogue(first)
            if index == 0 { mac.replica = replica } else { phone.replica = replica }
        }
        return (mac, phone, base)
    }

    @Test("Mac Blocks and iPhone imports at the same revision while apart: both end on one list, with Block", arguments: [true, false])
    func sameRevisionConflictConverges(phoneWritesFirst: Bool) async throws {
        var (mac, phone, _) = try Self.pair()
        let pipe = InMemoryCloudPipe()
        // Apart: each signs revision 2 from revision 1.
        let blocked = try mac.signed(catalogue(2, [login("shop", rule: .blocked, version: 0, at: 5_000, by: mac.id)]))
        let imported = try phone.signed(catalogue(2, [login("shop", rule: .ask, version: 2, at: 1_000, by: mac.id),
                                                      login("bank", rule: .ask, version: 2, at: 4_000, by: phone.id)]))
        mac.replica.signCatalogue(blocked)
        phone.replica.signCatalogue(imported)

        // Back together: one writes iCloud's catalogue first, the other finds it there.
        if phoneWritesFirst {
            try await push(&phone, to: pipe)
            try await push(&mac, to: pipe)
        } else {
            try await push(&mac, to: pipe)
            try await push(&phone, to: pipe)
        }
        try await pull(&mac, from: pipe)
        try await pull(&phone, from: pipe)

        let onMac = try #require(mac.replica.effectiveCatalogue)
        let onPhone = try #require(phone.replica.effectiveCatalogue)
        #expect(onMac == onPhone)
        #expect(onMac.revision == 2)
        let shop = try #require(onMac.logins.first { $0.loginID == "shop" })
        #expect(shop.rule == .blocked)
        #expect(shop.version == 0)
        #expect(!shop.holdsSecret)
        #expect(onMac.logins.contains { $0.loginID == "bank" && $0.holdsSecret })
        #expect(mac.replica.catalogueContested && phone.replica.catalogueContested)

        // Either one signs the merged list as revision 3: both take it, and the contest is over.
        var next = onPhone
        next.revision = 3
        let resolved = try phone.signed(next)
        phone.replica.signCatalogue(resolved)
        try await push(&phone, to: pipe)
        try await pull(&mac, from: pipe)
        #expect(mac.replica.catalogue == resolved)
        #expect(!mac.replica.catalogueContested && !phone.replica.catalogueContested)
        #expect(mac.replica.effectiveCatalogue?.logins.first { $0.loginID == "shop" }?.rule == .blocked)
    }

    /// Login X Automatic and login L at revision 1. Apart, the iPhone Blocks X at revision 2, while the Mac makes
    /// two changes of its own, still listing X as Automatic, and reaches revision 3 without L (deleted).
    private static func apart(_ mac: Peer, _ phone: Peer) throws -> (phoneSide: Data, macSide: Data) {
        let phoneSide = try phone.signed(catalogue(2, [login("x", rule: .blocked, version: 0, at: 5_000, by: phone.id),
                                                       login("l", rule: .ask, version: 1, at: 1_000, by: mac.id)]))
        let macSide = try mac.signed(catalogue(3, [login("x", rule: .automatic, version: 1, at: 1_000, by: mac.id),
                                                   login("y", rule: .ask, version: 3, at: 4_000, by: mac.id)]))
        return (phoneSide, macSide)
    }

    private static func automaticPair() throws -> (mac: Peer, phone: Peer) {
        var (mac, phone, _) = try pair()
        let first = try mac.signed(catalogue(1, [login("x", rule: .automatic, version: 1, at: 1_000, by: mac.id),
                                                 login("l", rule: .ask, version: 1, at: 1_000, by: mac.id)]))
        mac.replica.signCatalogue(first)
        phone.replica.signCatalogue(first)
        return (mac, phone)
    }

    @Test("An offline Block at revision 2 survives the Mac's revision 3, whichever device reaches iCloud first",
          arguments: [true, false])
    func offlineBlockSurvivesLaterRevision(phoneWritesFirst: Bool) async throws {
        var (mac, phone) = try Self.automaticPair()
        let pipe = InMemoryCloudPipe()
        let (phoneSide, macSide) = try Self.apart(mac, phone)
        phone.replica.signCatalogue(phoneSide)
        mac.replica.signCatalogue(macSide)

        if phoneWritesFirst {
            try await push(&phone, to: pipe)
            try await push(&mac, to: pipe)
        } else {
            try await push(&mac, to: pipe)
            try await push(&phone, to: pipe)
        }
        try await pull(&mac, from: pipe)
        try await pull(&phone, from: pipe)

        let onMac = try #require(mac.replica.effectiveCatalogue)
        let onPhone = try #require(phone.replica.effectiveCatalogue)
        #expect(onMac == onPhone)
        #expect(onMac.revision == 3)
        #expect(mac.replica.catalogue == macSide && phone.replica.catalogue == macSide)
        #expect(mac.replica.contestedCatalogues == [phoneSide] && phone.replica.contestedCatalogues == [phoneSide])
        let x = try #require(onMac.logins.first { $0.loginID == "x" })
        #expect(x.rule == .blocked && x.version == 0 && x.ruleActor == phone.id)
        // Which logins there are stays the later revision's: the Mac's deletion of L is not undone.
        #expect(onMac.logins.map(\.loginID) == ["x", "y"])
        // iCloud's shared record was never written over with a list that drops the Block.
        let shared = try #require(pipe.records[CloudRecordKind.catalogue])
        let opened = try #require(CloudEnvelope.openCloudEnvelope(shared.payload, expectedKind: CloudRecordKind.catalogue, deviceID: mac.id, opener: mac.opener))
        #expect(opened.plaintext == (phoneWritesFirst ? phoneSide : macSide))

        // The iPhone signs the merge as revision 4: both take it, and the contest is over with X still Blocked.
        var next = onPhone
        next.revision = 4
        let resolved = try phone.signed(next)
        phone.replica.signCatalogue(resolved)
        try await push(&phone, to: pipe)
        try await pull(&mac, from: pipe)
        #expect(mac.replica.catalogue == resolved)
        #expect(!mac.replica.catalogueContested && !phone.replica.catalogueContested)
        #expect(mac.replica.effectiveCatalogue?.logins.first { $0.loginID == "x" }?.rule == .blocked)
    }

    @Test("A later revision that saw the Block takes over cleanly, with no contest")
    func laterRevisionThatSawTheBlockIsNoContest() throws {
        var (mac, phone) = try Self.automaticPair()
        let members = try #require(phone.replica.currentMembers)
        let (phoneSide, _) = try Self.apart(mac, phone)
        phone.replica.signCatalogue(phoneSide)
        #expect(try mac.replica.intakeCatalogue(phoneSide, members: members) == .newer)
        // The Mac signs its next list from what it holds: the Block is carried, with the iPhone's time.
        let held = try #require(mac.replica.effectiveCatalogue)
        let later = try mac.signed(catalogue(3, held.logins + [login("y", rule: .ask, version: 3, at: 6_000, by: mac.id)]))
        #expect(try phone.replica.intakeCatalogue(later, members: members) == .newer)
        #expect(!phone.replica.catalogueContested)
        #expect(try phone.replica.intakeCatalogue(phoneSide, members: members) == .older)
        #expect(!phone.replica.catalogueContested)
        #expect(CloudCatalogue.givesWay(phoneSide, to: try #require(phone.replica.effectiveCatalogue), members: members))
    }

    @Test("An earlier list with the same rule stamped later is no contest, in either order")
    func sameRuleStampedLaterIsNoContest() throws {
        let (mac, phone) = try Self.automaticPair()
        let members = try #require(mac.replica.currentMembers)
        // The iPhone's import stamped X Automatic at 5000; the Mac's next list carries it from the vault unstamped.
        let stamped = try phone.signed(catalogue(2, [login("x", rule: .automatic, version: 1, at: 5_000, by: phone.id)]))
        let unstamped = try mac.signed(catalogue(3, [login("x", rule: .automatic, version: 1, at: 0, by: "")]))
        var first = mac.replica
        #expect(try first.intakeCatalogue(stamped, members: members) == .newer)
        #expect(try first.intakeCatalogue(unstamped, members: members) == .newer)
        var second = mac.replica
        #expect(try second.intakeCatalogue(unstamped, members: members) == .newer)
        #expect(try second.intakeCatalogue(stamped, members: members) == .older)
        #expect(!first.catalogueContested && !second.catalogueContested)
    }

    @Test("The three documents end on one list in every delivery order")
    func unequalRevisionsConvergeInEveryOrder() throws {
        let (mac, phone) = try Self.automaticPair()
        let members = try #require(mac.replica.currentMembers)
        let (phoneSide, macSide) = try Self.apart(mac, phone)
        let macMiddle = try mac.signed(catalogue(2, [login("x", rule: .automatic, version: 1, at: 1_000, by: mac.id)]))
        let documents = [phoneSide, macMiddle, macSide]
        var results: Set<Data> = []
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var replica = mac.replica
            for index in order { try replica.intakeCatalogue(documents[index], members: members) }
            let effective = try #require(replica.effectiveCatalogue)
            #expect(effective.revision == 3, "Order \(order)")
            #expect(effective.logins.first { $0.loginID == "x" }?.rule == .blocked, "Order \(order)")
            results.insert(try effective.serializedData())
            // Delivered again, nothing changes.
            for index in order { try replica.intakeCatalogue(documents[index], members: members) }
            #expect(replica.effectiveCatalogue == effective, "Order \(order) again")
        }
        #expect(results.count == 1)
    }

    @Test("Merging catalogues is commutative, associative and idempotent, with Block winning a tie")
    func catalogueMergeLaws() {
        let a = catalogue(4, [login("x", rule: .ask, version: 3, at: 2_000, by: "a"), login("y", rule: .automatic, version: 1, at: 1_000, by: "a")])
        let b = catalogue(4, [login("x", rule: .blocked, version: 0, at: 2_000, by: "a"), login("z", rule: .ask, version: 2, at: 1_500, by: "b")])
        let c = catalogue(4, [login("y", rule: .ask, version: 5, at: 3_000, by: "c")])
        #expect(CatalogueMerge.mergeCatalogues(a, b) == CatalogueMerge.mergeCatalogues(b, a))
        #expect(CatalogueMerge.mergeCatalogues(CatalogueMerge.mergeCatalogues(a, b), c) == CatalogueMerge.mergeCatalogues(a, CatalogueMerge.mergeCatalogues(b, c)))
        #expect(CatalogueMerge.mergeCatalogues(a, a) == a)
        let merged = CatalogueMerge.mergeCatalogues(CatalogueMerge.mergeCatalogues(a, b), c)
        #expect(merged.logins.map(\.loginID) == ["x", "y", "z"])
        #expect(merged.logins[0].rule == .blocked)
        #expect(merged.logins[1].rule == .ask && merged.logins[1].version == 5)
    }

    @Test("A catalogue older than, or the same as, the one held changes nothing")
    func olderAndSameCatalogues() throws {
        var (mac, phone, base) = try Self.pair()
        let members = try #require(mac.replica.currentMembers)
        let held = try #require(mac.replica.catalogue)
        #expect(try mac.replica.intakeCatalogue(held, members: members) == .unchanged)
        #expect(try mac.replica.intakeCatalogue(try phone.signed(catalogue(1, base)), members: members) == .unchanged)
        let other = base + [login("bank", rule: .ask, version: 1, at: 2_000, by: phone.id)]
        #expect(try mac.replica.intakeCatalogue(try phone.signed(catalogue(1, other)), members: members) == .contested)
        mac.replica.signCatalogue(try mac.signed(catalogue(2, base)))
        #expect(try mac.replica.intakeCatalogue(held, members: members) == .older)
        #expect(!mac.replica.catalogueContested)
        let stranger = Peer(kind: .iphone)
        #expect(throws: (any Error).self) { try phone.replica.intakeCatalogue(try stranger.signed(catalogue(9, base)), members: members) }
    }

    // MARK: The Mac's saved lists

    /// A store whose writes can be made to fail, and whose reads can be made to throw or return junk.
    final class Store {
        var items: [String: Data] = [:]
        var failWrites = false
        var readError: Error?
        var writes = 0

        @MainActor var storage: MacKeychainStateStore {
            MacKeychainStateStore(load: { [self] name in
                if let readError { throw readError }
                return items[name]
            }, write: { [self] bytes, name in
                writes += 1
                if failWrites { throw CocoaError(.fileWriteNoPermission) }
                items[name] = bytes
            })
        }
    }

    func mac(_ keys: MacKeys, _ store: Store, _ pipe: (any CloudPipe)?, in folder: URL) -> MacSyncCoordinator {
        var environment = MacSyncEnvironment(storage: store.storage)
        environment.cloud = pipe
        environment.complaints = folder.appending(path: "complaints.pb")
        let leases = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases")))
        return MacSyncCoordinator(keys: keys, store: MacVaultFileStore(directory: folder.appending(path: "logins")), leaseStore: leases,
                         environment: environment) { [] }
    }

    @Test("A pull whose save fails leaves the checkpoint where it was, and the next launch takes the records again")
    func failedSaveKeepsCheckpoint() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [keys.device]
        let signed = try CredentialSealing.signedDocument(members.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: LAContext()) }
        let pipe = InMemoryCloudPipe()
        try await pipe.writeCloudRecords([CloudRecord(kind: CloudRecordKind.members, writer: "another-device",
                                        payload: try CloudMembers.payload(current: try signed.serializedData(), history: []))])
        let store = Store()
        store.failWrites = true
        let failing = mac(keys, store, pipe, in: folder)
        defer { failing.stopBackgroundWork() }
        #expect(!(await failing.cloudSync.pullCloudNow()))
        #expect(failing.saved.cloudCheckpoint.changeToken == nil)
        #expect(store.items["saved"] == nil)

        // Relaunched with the disk as it was: nothing of the failed pull was kept, and it is all taken again.
        store.failWrites = false
        let relaunched = mac(keys, store, pipe, in: folder)
        defer { relaunched.stopBackgroundWork() }
        #expect(relaunched.members == nil)
        #expect(await relaunched.cloudSync.pullCloudNow())
        #expect(relaunched.members?.revision == 1)
        let saved = try MacSyncCoordinator.MacSavedLists.decodeProtobuf(try #require(store.items["saved"]))
        #expect(saved.members == (try signed.serializedData()))
        #expect(saved.cloudCheckpoint.changeToken != nil)
        #expect(saved.cloudCheckpoint.knownNames.contains(CloudRecordKind.members))

        // Nothing new since: the next pull starts after the saved token.
        #expect(try await pipe.fetchCloudChanges(since: saved.cloudCheckpoint.changeToken).records.isEmpty)
    }

    @Test("The Mac starts empty with nothing saved, holds lists the keychain cannot read, and starts again from lists it cannot decode")
    func savedListsAbsentUnreadableOrCorrupt() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")

        let absent = Store()
        let fresh = mac(keys, absent, nil, in: folder)
        #expect(!fresh.savedListsLocked)
        #expect(fresh.persist())
        #expect(absent.items["saved"] != nil)

        let locked = Store()
        locked.readError = CocoaError(.fileReadNoPermission)
        let unreadable = mac(keys, locked, nil, in: folder)
        #expect(unreadable.savedListsLocked)
        #expect(!unreadable.persist())
        #expect(locked.writes == 0)

        let junk = Store()
        junk.items["saved"] = Data("not the lists".utf8)
        let corrupt = mac(keys, junk, nil, in: folder)
        #expect(!corrupt.savedListsLocked)
        #expect(corrupt.persist())
        #expect(try MacSyncCoordinator.MacSavedLists.decodeProtobuf(#require(junk.items["saved"])).members == nil)
    }

    /// Members at revision 1 listing this Mac, as a device and as a computer, signed by it.
    private func ownMembers(_ keys: MacKeys, with others: [Agentkeyring_V2_Device] = []) throws -> (Members, Data) {
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [keys.device] + others
        members.machines = [keys.machine]
        let signed = try CredentialSealing.signedDocument(members.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: LAContext()) }
        return (members, try signed.serializedData())
    }

    func signed(_ catalogue: Catalogue, by keys: MacKeys) throws -> Data {
        try CredentialSealing.signedDocument(catalogue.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: LAContext()) }.serializedData()
    }

    @Test("The Mac Blocks a password and adds an Automatic one while the iPhone imports at the same revision: both stay")
    func contestedCatalogueKeepsMacChanges() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let phone = Peer(kind: .iphone)
        let (_, signedMembers) = try ownMembers(keys, with: [phone.device])
        let store = MacVaultFileStore(directory: folder.appending(path: "logins"))
        let model = MacKeyringEngine(store: store,
                                   accessControl: CredentialAccessController(store: LoginRuleStore(read: { nil }, write: { _ in })),
                                   leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases"))),
                                   settings: try #require(UserDefaults(suiteName: UUID().uuidString)))
        model.enableBackgroundOnDeviceSorting = false
        model.adopt(keys, environment: MacSyncEnvironment(storage: .memory()), leavingInvitation: false)
        let device = try #require(model.device)
        defer { device.stopBackgroundWork() }
        let (shop, extra, bank) = (UUID(), UUID(), UUID())
        #expect(await device.receiveSignedMembers(signedMembers) == .taken)
        let imported = login(shop.uuidString, rule: .ask, version: 1, at: 0, by: "")
        #expect(await device.receiveSignedCatalogue(try signed(catalogue(1, [imported]), by: keys)) == .taken)

        // Apart: the Mac Blocks one password and makes another Automatic, with its own copy for its own
        // agents; the iPhone imports a third.
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = extra.uuidString
        secret.password = "p"
        let ownCopy = try CredentialSealing.sealLogin(secret, version: 7, to: keys.receiving.publicKey, openerID: keys.machineID, signer: keys.signer)
        try await store.replaceSealed([ownCopy])
        let macSide = catalogue(2, [login(shop.uuidString, rule: .blocked, version: 0, at: 5_000, by: keys.deviceKeyID),
                                    login(extra.uuidString, rule: .automatic, version: 7, at: 5_000, by: keys.deviceKeyID)])
        #expect(await device.receiveSignedCatalogue(try signed(macSide, by: keys)) == .taken)
        let phoneSide = catalogue(2, [imported, login(bank.uuidString, rule: .ask, version: 2, at: 0, by: "")])
        #expect(await device.receiveSignedCatalogue(try phone.signed(phoneSide)) == .taken)

        #expect(device.saved.catalogueContested)
        #expect(model.accessControl.rule(for: shop) == .blocked)
        #expect(model.accessControl.rule(for: extra) == .automatic)
        #expect(model.accessControl.rule(for: bank) == .ask)
        #expect(device.catalogue?.logins.first { $0.loginID == shop.uuidString }?.rule == .blocked)
        #expect(try await store.sealed().contains(ownCopy))
    }

    @Test("A second push token in the same second wins wherever it arrives, in either order", arguments: [true, false])
    func sameSecondPushRotation(newestFirst: Bool) throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let device = mac(keys, Store(), nil, in: folder)
        // Apple's second token sorts before its first, so only the signed time can order them.
        device.registerPush(token: Data(repeating: 0xFF, count: 32), topic: "topic", production: false)
        let first = try #require(device.saved.pushRegistrations[keys.deviceKeyID])
        device.registerPush(token: Data(repeating: 0x01, count: 32), topic: "topic", production: false)
        let second = try #require(device.saved.pushRegistrations[keys.deviceKeyID])
        func time(_ bytes: Data) throws -> Int64 {
            try Agentkeyring_V2_PushRegistration(serializedBytes: try SignedDocument(serializedBytes: bytes).payload).registeredUnixSeconds
        }
        #expect(try time(second) > time(first))

        let (members, signedMembers) = try ownMembers(keys)
        var peer = TestReplica()
        peer.adoptMembers(members, signed: signedMembers)
        for bytes in newestFirst ? [second, first] : [first, second] { _ = try peer.takePushRegistration(bytes, members: members) }
        #expect(peer.pushRegistrations[keys.deviceKeyID] == second)
    }

    @Test("Lists the keychain could not read at launch are read again once it can, and saved from then on")
    func savedListsReadAgain() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        var lists = MacSyncCoordinator.MacSavedLists()
        lists.members = try ownMembers(keys).1
        let store = Store()
        store.items["saved"] = MacSyncCoordinator.savedProtobufMagic + (try lists.storedProto().serializedData())
        store.readError = CocoaError(.fileReadNoPermission)
        let device = mac(keys, store, nil, in: folder)
        defer { device.stopBackgroundWork() }
        #expect(device.savedListsLocked && device.members == nil)
        #expect(!device.retryLoadSavedLists())
        #expect(!device.persist())

        store.readError = nil
        #expect(device.retryLoadSavedLists())
        #expect(!device.savedListsLocked)
        #expect(device.members?.revision == 1)
        #expect(device.persist())
        #expect(store.writes == 1)
    }

    @Test("Lists missing from a full read, or gone with their zone, are read as gone and written again")
    func zoneResetWritesListsAgain() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let pipe = InMemoryCloudPipe()
        let device = mac(keys, Store(), pipe, in: folder)
        defer { device.stopBackgroundWork() }
        func acceptedAgain() async {
            #expect(device.saved.cloudAcceptedMembers == nil && device.saved.cloudAcceptedCatalogue == nil)
            #expect(device.saved.cloudPushPending(by: keys.deviceKeyID))
            await device.cloudSync.pushCloudNow()
            #expect(pipe.records[CloudRecordKind.members] != nil && pipe.records[CloudRecordKind.catalogue] != nil)
            #expect(device.saved.cloudAcceptedMembers == device.saved.members)
            #expect(device.saved.cloudAcceptedCatalogue == device.saved.catalogue)
        }
        #expect(await device.receiveSignedMembers(try ownMembers(keys).1) == .taken)
        #expect(await device.receiveSignedCatalogue(try signed(catalogue(1, []), by: keys)) == .taken)
        await device.cloudSync.pushCloudNow()
        #expect(device.saved.cloudCheckpoint.knownNames.isSuperset(of: [CloudRecordKind.members, CloudRecordKind.catalogue]))

        // Written before any pull, then the zone deleted: the first read, from no token, finds neither.
        pipe.simulateZoneReset()
        #expect(await device.cloudSync.pullCloudNow())
        await acceptedAgain()

        // Read since, then deleted again: the next read, from a token of the zone before, starts over.
        #expect(await device.cloudSync.pullCloudNow())
        pipe.simulateZoneReset()
        #expect(await device.cloudSync.pullCloudNow())
        await acceptedAgain()
    }

    @Test("An iPhone that cannot read its saved state yet writes nothing over it, and reads it once it can")
    func phoneStateLockedUntilUnlock() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var held = PhoneSavedState()
        held.deviceKeyID = "this-iphone"
        let file = folder.appending(path: "phone-v2.pb")
        try held.encodeProtobuf().write(to: file)
        // As before the first unlock after a restart: there, and unreadable.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let phone = PhoneKeyringEngine(directory: folder, shared: PhoneSharedContext(accessGroup: nil), keys: NoKeys(),
                                 identity: { throw CancellationError() }, cloud: nil)
        #expect(phone.stateFileLocked)
        #expect(!phone.save(PhoneSavedState()))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try PhoneSavedState.decodeProtobuf(Data(contentsOf: file)).deviceKeyID == "this-iphone")
        #expect(phone.loadState())
        #expect(!phone.stateFileLocked)
        #expect(phone.state.deviceKeyID == "this-iphone")
        #expect(phone.save(phone.state))
    }

    @Test("Complaints are kept to the newest that fit in half a socket frame")
    func complaintsFitTheFrame() {
        var big = Agentkeyring_V2_Complaint()
        big.detail = String(repeating: "x", count: 60_000)
        let all = (0..<20).map { index -> Agentkeyring_V2_Complaint in
            var complaint = big
            complaint.summary = "\(index)"
            return complaint
        }
        let kept = MacSyncCoordinator.newest(all, within: MacSyncCoordinator.complaintsBytes)
        var list = Agentkeyring_V2_Complaints()
        list.complaints = kept
        #expect(((try? list.serializedData().count) ?? .max) <= MacSyncCoordinator.complaintsBytes)
        #expect(kept.last?.summary == "19")
        #expect(kept.count < all.count)
    }
}
