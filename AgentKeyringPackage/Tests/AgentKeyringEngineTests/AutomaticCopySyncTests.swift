// Written by AI on 2026.11.27 by model gemini-4-neon.
//
// The iPhone sets a password to Always Allowed: it seals the Mac's machine copy and syncs it through
// iCloud, so the Mac serves the password with no second Touch ID; Ask First again drops the copy everywhere.

import AgentKeyringApprovalCore
@testable import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Testing

@Suite("Automatic copy sync from iPhone to Mac")
struct AutomaticCopySyncTests {
    @Test("Setting Always Allowed on iPhone seals and syncs Mac's machine copy so Mac never prompts for a second Touch ID")
    @MainActor
    func iphoneAutomaticRuleSyncsMachineCopyToMacWithoutPrompt() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akr-auto-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let suite = "akr-auto-sync-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }

        // 1. Real Mac model and real MacSyncCoordinator with a stored login (currently .ask).
        let macStore = MacVaultFileStore(directory: folder.appending(path: "mac-store"))
        let leaseStore = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "mac-leases")))
        let policyStore = LoginRuleStore(read: { nil }, write: { _ in })
        let macKeys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "MacBook Pro")
        let loginID = UUID()
        let version: UInt64 = 1_000_000
        let item = StoredVaultLogin(
            id: loginID,
            sourceIdentity: LoginSourceIdentity(exporterIdentifier: "com.apple.Passwords", accountID: Data("acct".utf8), itemID: Data(loginID.uuidString.utf8)),
            lastModifiedAt: .now,
            title: "Example",
            origins: ["https://example.com"],
            credentials: [.password(userName: "alex@example.com", password: "s3cret-pass")]
        )
        let generation = StoredVaultSnapshot(
            id: UUID(),
            previousSnapshotID: nil,
            createdAt: .now,
            sourceExportedAt: .now,
            scope: .selected,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: [item],
            skippedCredentialCount: 0
        )

        // 2. Real iPhone keys and shared Members (Mac device + Mac machine + iPhone device).
        let phoneKeys = OpeningCapablePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()

        var members = Agentkeyring_V2_Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [macKeys.device, phoneDevice]
        members.machines = [macKeys.machine]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: macKeys.deviceKeyID) {
            try macKeys.signWithDeviceKey($0, context: LAContext())
        }
        let signedMembersBytes = try signedMembers.serializedData()

        // Seal initial copies (Ask rule: Mac chip key + iPhone opening key, NO machine copy yet).
        let macCopy = try CredentialSealing.sealLogin(item.secret, version: version, to: macKeys.openingPublicKey, openerID: macKeys.deviceKeyID, signer: macKeys.signer)
        let phoneCopy = try CredentialSealing.sealLogin(item.secret, version: version, to: phoneKeys.opening.publicKey, openerID: phoneKeyID, signer: macKeys.signer)
        try await macStore.save(generation) { _ in [macCopy, phoneCopy] }

        var initialCatalogue = Agentkeyring_V2_Catalogue()
        initialCatalogue.domain = "agentkeyring.catalogue.v2"
        initialCatalogue.revision = 1
        var catLogin = Agentkeyring_V2_Login()
        catLogin.loginID = loginID.uuidString
        catLogin.title = item.title
        catLogin.sites = item.origins
        catLogin.account = item.accountName ?? ""
        catLogin.rule = .ask
        catLogin.version = version
        initialCatalogue.logins = [catLogin]
        let signedInitialCatalogue = try CredentialSealing.signedDocument(initialCatalogue.serializedData(), by: macKeys.deviceKeyID) {
            try macKeys.signWithDeviceKey($0, context: LAContext())
        }

        let model = MacKeyringEngine(
            store: macStore,
            accessControl: CredentialAccessController(store: policyStore),
            leaseStore: leaseStore,
            settings: settings
        )
        model.enableBackgroundOnDeviceSorting = false
        let loadedMeta = try await macStore.loadCurrentMetadata()
        model.status = loadedMeta?.safeStatus
        model.leaseLogins = loadedMeta?.candidates ?? []
        await model.accessControl.refresh(fromMetadata: loadedMeta)
        model.adopt(macKeys, environment: MacSyncEnvironment(storage: .memory()), leavingInvitation: false)
        let macDevice = try #require(model.device)
        #expect(await macDevice.receiveSignedMembers(signedMembersBytes) == .taken)
        #expect(await macDevice.receiveSignedCatalogue(try signedInitialCatalogue.serializedData()) == .taken)
        #expect(!model.automaticCopiesMissing)
        #expect(model.localAutomaticCopyIDs.isEmpty)

        // 3. Real PhoneKeyringEngine holding the same Members, Catalogue, and its own sealed copy.
        let phoneDir = folder.appending(path: "phone")
        try FileManager.default.createDirectory(at: phoneDir, withIntermediateDirectories: true)
        var phoneSaved = PhoneSavedState()
        phoneSaved.deviceKeyID = phoneKeyID
        phoneSaved.members = signedMembersBytes
        phoneSaved.catalogue = try signedInitialCatalogue.serializedData()
        var phoneOwned = Agentkeyring_V2_SealedLogins()
        phoneOwned.logins = [phoneCopy]
        phoneSaved.copies = try phoneOwned.serializedData()
        try phoneSaved.encodeProtobuf().write(to: phoneDir.appending(path: "phone-v2.pb"))

        let phone = PhoneKeyringEngine(
            directory: phoneDir,
            shared: PhoneSharedContext(accessGroup: nil),
            keys: phoneKeys,
            identity: { try DeviceTLSIdentity.ephemeral() }
        )

        // 4. User switches login to Always Allowed on iPhone (single Face ID).
        try await phone.setLoginRule(.automatic, forLogin: loginID.uuidString)

        // iPhone must now hold a valid Automatic copy sealed for Mac's machineID.
        let machineCopies = phone.madeForOthers.filter { $0.openerID == macKeys.machineID && $0.loginID == loginID.uuidString }
        #expect(machineCopies.count == 1)

        // CloudCopies packs and verifies machine copies for Mac's machineID.
        let cloudRecords = try CloudCopies.records(machineCopies, for: macKeys.machineID, writer: phoneKeyID)
        #expect(cloudRecords.count == 1)
        let newCatalogueBytes = try #require(phone.state.catalogue)
        let newCatalogueDoc = try SignedDocument(serializedBytes: newCatalogueBytes)
        let newCatalogue = try Agentkeyring_V2_Catalogue(serializedBytes: newCatalogueDoc.payload)
        let checked = CloudCopies.checked(cloudRecords[0].payload, for: macKeys.machineID, members: members, catalogue: newCatalogue)
        #expect(checked.count == 1)

        // 5. Mac pulls both the updated Catalogue and copies-<machineID> in one iCloud pull batch.
        var promptFlashed = false
        macDevice.cloudSync.takingSealedRecords = true
        #expect(await macDevice.receiveSignedCatalogue(newCatalogueBytes) == .taken)
        if model.automaticCopiesMissing { promptFlashed = true }
        var batch = Agentkeyring_V2_SealedLogins()
        batch.logins = checked
        #expect(await macDevice.receiveSealedCopies(try batch.serializedData()))
        macDevice.cloudSync.takingSealedRecords = false
        await model.noteMissingAutomaticCopies()

        #expect(!promptFlashed)
        #expect(!model.automaticCopiesMissing)
        #expect(model.localAutomaticCopyIDs.contains(loginID.uuidString))

        // 6. Verify Mac can actually open and serve the password from the iPhone-sealed machine copy.
        var leaseReq = Agentkeyring_V2_RequestLeaseRequest()
        leaseReq.requestID = "req-auto-1"
        leaseReq.loginID = loginID.uuidString
        leaseReq.taskRef = "task-1"
        leaseReq.reason = "Check dashboard"
        let candidate = try #require(model.leaseLogins.first { $0.id == loginID })
        let granted = try model.leaseStore.recordLeaseRequest(leaseReq, login: candidate, rule: .automatic)
        #expect(granted.state == .approved)
        let values = try await model.values(for: granted, fields: [.username, .password])
        #expect(values.username == "alex@example.com")
        #expect(values.password == "s3cret-pass")

        // 7. Switching back to Ask on iPhone drops the machine copy on both iPhone and Mac.
        try await phone.setLoginRule(.ask, forLogin: loginID.uuidString)
        #expect(phone.madeForOthers.filter { $0.openerID == macKeys.machineID }.isEmpty)
        let askCatalogueBytes = try #require(phone.state.catalogue)
        #expect(await macDevice.receiveSignedCatalogue(askCatalogueBytes) == .taken)
        #expect(model.localAutomaticCopyIDs.isEmpty)
        #expect(!model.automaticCopiesMissing)
    }
}
