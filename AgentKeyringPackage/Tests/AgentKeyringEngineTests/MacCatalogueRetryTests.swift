// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The Mac keeps a change it could not save eligible to come again: a catalogue
// from iCloud whose rules could not be written leaves the pull's checkpoint
// where it was and is taken whole on the next pull, and a Send Updates whose
// copies could not be pruned leaves the contest unsent for the next try.

@testable import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@MainActor
struct MacCatalogueRetryTests {
    /// An iPhone in the list: its keys sign catalogues, its notice key opens what iCloud holds for it.
    private struct Phone {
        let signing = P256.Signing.PrivateKey()
        let notice = P256.KeyAgreement.PrivateKey()

        var id: String { CredentialSealing.keyID(signing.publicKey.x963Representation) }

        var device: Agentkeyring_V2_Device {
            var device = Agentkeyring_V2_Device()
            device.kind = .iphone
            device.signingPublicKey = signing.publicKey.x963Representation
            device.keyID = id
            device.noticePublicKey = notice.publicKey.x963Representation
            return device
        }

        func signed(_ catalogue: Catalogue) throws -> Data {
            try CredentialSealing.signedDocument(catalogue.serializedData(), by: id) { try signing.signature(for: $0).derRepresentation }.serializedData()
        }
    }

    /// Writes to the rules' store fail while `failing` is set.
    private final class RulesStore {
        var failing = false
        var saved: Data?

        @MainActor var store: LoginRuleStore {
            LoginRuleStore(read: { [self] in saved }, write: { [self] bytes in
                if failing { throw CocoaError(.fileWriteNoPermission) }
                saved = bytes
            })
        }
    }

    private struct Setup {
        let model: MacKeyringEngine
        let device: MacSyncCoordinator
        let keys: MacKeys
        let phone: Phone
        let members: Members
    }

    private func setUp(in folder: URL, rules: RulesStore, cloud: InMemoryCloudPipe?) async throws -> Setup {
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let phone = Phone()
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [keys.device, phone.device]
        members.machines = [keys.machine]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: LAContext()) }
        let model = MacKeyringEngine(store: MacVaultFileStore(directory: folder.appending(path: "logins")),
                                   accessControl: CredentialAccessController(store: rules.store),
                                   leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases"))),
                                   settings: try #require(UserDefaults(suiteName: UUID().uuidString)))
        model.enableBackgroundOnDeviceSorting = false
        var environment = MacSyncEnvironment(storage: .memory())
        environment.cloud = cloud
        model.adopt(keys, environment: environment, leavingInvitation: false)
        let device = try #require(model.device)
        #expect(await device.receiveSignedMembers(try signedMembers.serializedData()) == .taken)
        return Setup(model: model, device: device, keys: keys, phone: phone, members: members)
    }

    private func login(_ id: UUID, rule: Agentkeyring_V2_Rule, version: UInt64, at ms: Int64, by actor: String) -> Agentkeyring_V2_Login {
        var login = Agentkeyring_V2_Login()
        login.loginID = id.uuidString
        login.title = "Shop"
        login.rule = rule
        login.version = version
        login.ruleUpdatedUnixMs = ms
        login.ruleActor = actor
        return login
    }

    private func catalogue(_ revision: UInt64, _ logins: [Agentkeyring_V2_Login]) -> Catalogue {
        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = revision
        catalogue.logins = logins
        return catalogue
    }

    private func signed(_ catalogue: Catalogue, by keys: MacKeys) throws -> Data {
        try CredentialSealing.signedDocument(catalogue.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: LAContext()) }.serializedData()
    }

    @Test("A catalogue whose rules could not be saved is not acknowledged, and the next pull takes it whole")
    func failedPolicyWriteRetries() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rules = RulesStore()
        let pipe = InMemoryCloudPipe()
        let setup = try await setUp(in: folder, rules: rules, cloud: pipe)
        defer { setup.device.stopBackgroundWork() }
        let shop = UUID()
        let first = catalogue(1, [login(shop, rule: .automatic, version: 1, at: 1_000, by: setup.keys.deviceKeyID)])
        #expect(await setup.device.receiveSignedCatalogue(try signed(first, by: setup.keys)) == .taken)
        #expect(setup.model.accessControl.rule(for: shop) == .automatic)

        // The iPhone makes it Ask First; iCloud brings it while the rules cannot be saved.
        let ask = try setup.phone.signed(catalogue(2, [login(shop, rule: .ask, version: 1, at: 5_000, by: setup.phone.id)]))
        let sealed = try CloudEnvelope.seal(ask, kind: CloudRecordKind.catalogue, recipients: CloudEnvelope.recipients(for: setup.members))
        try await pipe.writeCloudRecords([CloudRecord(kind: CloudRecordKind.catalogue, writer: setup.phone.id, payload: sealed)])
        rules.failing = true
        let checkpoint = setup.device.saved.cloudCheckpoint
        #expect(!(await setup.device.cloudSync.pullCloudNow()))
        #expect(setup.device.saved.cloudCheckpoint == checkpoint)
        #expect(setup.device.saved.cloudAcceptedCatalogue != ask)
        #expect(setup.device.catalogue?.revision == 1)
        #expect(setup.device.saved.catalogueRevision == 1)
        #expect(setup.model.accessControl.rule(for: shop) == .automatic)

        // Saved again: the same record is taken, not refused as one already held.
        rules.failing = false
        #expect(await setup.device.cloudSync.pullCloudNow())
        #expect(setup.device.catalogue?.revision == 2)
        #expect(setup.model.accessControl.rule(for: shop) == .ask)
        #expect(setup.device.saved.cloudCheckpoint != checkpoint)
        #expect(setup.device.saved.cloudAcceptedCatalogue == ask)
    }

    @Test("A Send Updates whose copies could not be pruned stays unsent, and the next one settles the contest")
    func failedPublishStaysRetryable() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let logins = folder.appending(path: "logins")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logins.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let setup = try await setUp(in: folder, rules: RulesStore(), cloud: nil)
        defer { setup.device.stopBackgroundWork() }
        let (shop, bank) = (UUID(), UUID())
        let base = login(shop, rule: .ask, version: 1, at: 0, by: "")
        #expect(await setup.device.receiveSignedCatalogue(try signed(catalogue(1, [base]), by: setup.keys)) == .taken)
        // Apart, at the same revision: the Mac Blocks one password and the iPhone imports another.
        let macSide = catalogue(2, [login(shop, rule: .blocked, version: 0, at: 5_000, by: setup.keys.deviceKeyID)])
        #expect(await setup.device.receiveSignedCatalogue(try signed(macSide, by: setup.keys)) == .taken)
        let phoneSide = catalogue(2, [base, login(bank, rule: .ask, version: 2, at: 0, by: "")])
        #expect(await setup.device.receiveSignedCatalogue(try setup.phone.signed(phoneSide)) == .taken)
        #expect(setup.device.saved.catalogueContested)
        #expect(setup.model.unsentChanges.total == 1)
        try await setup.model.store.replaceSealed([])

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: logins.path)
        await #expect(throws: (any Error).self) { try await setup.model.sendChanges(context: LAContext()) }
        #expect(setup.device.saved.catalogueContested)
        #expect(setup.device.catalogue?.revision == 2)
        #expect(setup.model.unsentChanges.total == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logins.path)
        try await setup.model.sendChanges(context: LAContext())
        #expect(!setup.device.saved.catalogueContested)
        #expect(setup.device.catalogue?.revision == 3)
        #expect(setup.model.unsentChanges.total == 0)
    }

    @Test("The Mac reports a failed copy write and can store the same copy on retry")
    func macCopyWriteFailure() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copiesURL = directory.appending(path: "copies")
        let store = MacVaultFileStore(directory: copiesURL)
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let leases = CredentialLeaseStore(persistence: LeasePersistence(directory: directory.appending(path: "leases")))
        let mac = MacSyncCoordinator(keys: keys, store: store, leaseStore: leases, environment: .init(storage: .memory())) { [] }
        defer { mac.stopBackgroundWork() }

        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [keys.device]
        members.machines = [keys.machine]
        let context = LAContext()
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: context) }
        try #require(await mac.receiveSignedMembers(try signedMembers.serializedData()) == .taken)

        var login = Agentkeyring_V2_Login()
        login.loginID = UUID().uuidString
        login.rule = .automatic
        login.version = 1
        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = 1
        catalogue.logins = [login]
        let signedCatalogue = try CredentialSealing.signedDocument(catalogue.serializedData(), by: keys.deviceKeyID) { try keys.signWithDeviceKey($0, context: context) }
        try #require(await mac.receiveSignedCatalogue(try signedCatalogue.serializedData()) == .taken)

        var secret = LoginSecret()
        secret.loginID = login.loginID
        secret.password = "example"
        let receivingKey = try P256.KeyAgreement.PublicKey(x963Representation: keys.machine.receivingPublicKey)
        let copy = try CredentialSealing.sealLogin(secret, version: login.version, to: receivingKey, openerID: keys.machineID, signer: keys.signer)
        var batch = Agentkeyring_V2_SealedLogins()
        batch.logins = [copy]
        let payload = try batch.serializedData()

        if FileManager.default.fileExists(atPath: copiesURL.path) {
            try FileManager.default.removeItem(at: copiesURL)
        }
        try Data([1]).write(to: copiesURL)
        #expect(!(await mac.receiveSealedCopies(payload)))
        try FileManager.default.removeItem(at: copiesURL)
        #expect(await mac.receiveSealedCopies(payload))
        #expect(try await store.sealed() == [copy])
    }
}
