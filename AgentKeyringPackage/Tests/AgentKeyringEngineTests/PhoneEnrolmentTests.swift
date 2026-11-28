// Written by AI on 2026.11.27 by model GPT-6.2 Sol.

@testable import AgentKeyringEngine
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@Suite("iPhone Apple Watch state")
struct PhoneWatchStateTests {
    @Test("Watch copiesGeneration floor recovery and watchCopiesPending self-heal")
    @MainActor func watchCopiesFloorRecoveryAndPendingSelfHeal() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let phoneKeys = SoftwarePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        let watchSigning = P256.Signing.PrivateKey()
        let watchOpening = P256.KeyAgreement.PrivateKey()
        let watchReply = P256.Signing.PrivateKey()
        let watchKeyID = CredentialSealing.keyID(watchSigning.publicKey.x963Representation)

        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())

        var watchDevice = Agentkeyring_V2_Device()
        watchDevice.keyID = watchKeyID
        watchDevice.kind = .watch
        watchDevice.label = "Apple Watch"
        watchDevice.signingPublicKey = watchSigning.publicKey.x963Representation
        watchDevice.openingPublicKey = watchOpening.publicKey.x963Representation
        watchDevice.replyPublicKey = watchReply.publicKey.x963Representation
        watchDevice.replyKeyID = CredentialSealing.keyID(watchReply.publicKey.x963Representation)

        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [phoneDevice, watchDevice]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        let loginID = UUID().uuidString
        var login = Agentkeyring_V2_Login()
        login.loginID = loginID
        login.title = "example.com"
        login.sites = ["example.com"]
        login.account = "you@example.com"
        login.rule = .ask
        login.version = 100
        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = 1
        catalogue.logins = [login]
        let signedCatalogue = try CredentialSealing.signedDocument(catalogue.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        var secret = LoginSecret()
        secret.loginID = loginID
        secret.title = "example.com"
        secret.sites = ["example.com"]
        secret.username = "you@example.com"
        secret.password = "pw"
        let watchCopy = try CredentialSealing.sealLogin(
            secret,
            version: 100,
            to: watchOpening.publicKey,
            openerID: watchKeyID,
            signer: PayloadReplySigner(keyID: phoneDevice.replyKeyID, sign: phoneKeys.signReply)
        )
        var madeBatch = Agentkeyring_V2_SealedLogins()
        madeBatch.logins = [watchCopy]

        var saved = PhoneSavedState()
        saved.deviceKeyID = phoneKeyID
        saved.members = try signedMembers.serializedData()
        saved.catalogue = try signedCatalogue.serializedData()
        saved.sealedForOthers = try madeBatch.serializedData()
        saved.watchCopiesPending = watchKeyID
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let keyring = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: phoneKeys,
                                   identity: { throw CancellationError() })

        // Self-heal: even with watchCopiesPending set, syncWatchCopiesSoon runs because copiesForWatch covers all eligible logins.
        var sentGenerations: [UInt64] = []
        keyring.onWatchCopies = { _, generation in
            sentGenerations.append(generation)
            if generation == 1 {
                // Simulate Watch having a higher floor (5) after an iPhone reset.
                Task { @MainActor in keyring.watchHolds(copiesGeneration: 5) }
            } else if generation == 6 {
                Task { @MainActor in keyring.watchHolds(copiesGeneration: 6) }
            }
        }

        let confirmed = try await keyring.sendWatchCopiesAndWait()
        #expect(confirmed)
        #expect(sentGenerations == [1, 6])
        #expect(keyring.state.watchCopiesHeld == 6)
        #expect(!keyring.watchCopiesPending)

        // syncWatchCopiesSoon must also schedule when watchCopiesPending is set and copiesForWatch covers all eligible logins.
        var pendingSaved = keyring.state
        pendingSaved.watchCopiesPending = watchKeyID
        keyring.save(pendingSaved)
        keyring.syncWatchCopiesSoon()
        for _ in 0..<50 where sentGenerations.count < 3 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(sentGenerations == [1, 6, 7])
    }

    @Test("PhoneDevice exposes explicit kind, readiness, alsoAsks via pairedMac, and WatchSelfTest proto")
    @MainActor func phoneDeviceExplicitStateAndSelfTestProto() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let phoneKeys = SoftwarePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        let macSigning = P256.Signing.PrivateKey()
        let macTLS = P256.Signing.PrivateKey()
        let macRecv = P256.KeyAgreement.PrivateKey()
        let watchSigning = P256.Signing.PrivateKey()
        let linuxTLS = P256.Signing.PrivateKey()

        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())

        var macDevice = Agentkeyring_V2_Device()
        macDevice.keyID = CredentialSealing.keyID(macSigning.publicKey.x963Representation)
        macDevice.kind = .mac
        macDevice.label = "MacBook Pro"
        macDevice.signingPublicKey = macSigning.publicKey.x963Representation
        macDevice.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        macDevice.openingPublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        macDevice.tlsPublicKey = macTLS.publicKey.derRepresentation

        var macMachine = Agentkeyring_V2_Machine()
        macMachine.machineID = CredentialSealing.keyID(macTLS.publicKey.derRepresentation)
        macMachine.label = "Renamed Mac"
        macMachine.tlsPublicKey = macTLS.publicKey.derRepresentation
        macMachine.receivingPublicKey = macRecv.publicKey.x963Representation

        var linuxMachine = Agentkeyring_V2_Machine()
        linuxMachine.machineID = CredentialSealing.keyID(linuxTLS.publicKey.derRepresentation)
        linuxMachine.label = "MacBook Pro" // Intentionally collides with macDevice.label to prove no string matching!
        linuxMachine.tlsPublicKey = linuxTLS.publicKey.derRepresentation
        linuxMachine.receivingPublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation

        var watchDevice = Agentkeyring_V2_Device()
        watchDevice.keyID = CredentialSealing.keyID(watchSigning.publicKey.x963Representation)
        watchDevice.kind = .watch
        watchDevice.label = "Apple Watch"
        watchDevice.signingPublicKey = watchSigning.publicKey.x963Representation
        watchDevice.openingPublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation

        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [phoneDevice, macDevice, watchDevice]
        members.machines = [macMachine, linuxMachine]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        var watchReg = Agentkeyring_V2_PushRegistration()
        watchReg.domain = "agentkeyring.push.v2"
        watchReg.deviceKeyID = watchDevice.keyID
        watchReg.apnsToken = Data(repeating: 0x12, count: 32)
        watchReg.apnsTopic = "com.joshpalmer.AgentKeyring.Watch"
        watchReg.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let signedWatchReg = try CredentialSealing.signedDocument(watchReg.serializedData(), by: phoneDevice.replyKeyID, sign: phoneKeys.signReply)

        var saved = PhoneSavedState()
        saved.deviceKeyID = phoneKeyID
        saved.members = try signedMembers.serializedData()
        saved.pushRegistrations = [watchDevice.keyID: try signedWatchReg.serializedData()]
        saved.watchCopiesPending = watchDevice.keyID
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let keyring = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: phoneKeys,
                                   identity: { throw CancellationError() })
        let devices = keyring.snapshot.devices
        let macRow = try #require(devices.first { $0.id == macDevice.keyID })
        #expect(macRow.kind == .mac)
        #expect(macRow.alsoAsks)
        #expect(macRow.readiness == .waitingForNotifications)
        #expect(!macRow.canPractice)

        // Paired Mac machine row is omitted via CredentialSealing.pairedMac, while Linux box sharing the label stays visible.
        #expect(!devices.contains { $0.id == macMachine.machineID })
        let linuxRow = try #require(devices.first { $0.id == linuxMachine.machineID })
        #expect(linuxRow.kind == .computer)
        #expect(linuxRow.role == .asks)
        #expect(!linuxRow.alsoAsks)

        // Watch with watchCopiesPending reports .syncingCopies, then .ready once copies clear.
        let watchSyncing = try #require(devices.first { $0.id == watchDevice.keyID })
        #expect(watchSyncing.kind == .watch)
        #expect(watchSyncing.readiness == .syncingCopies(done: 0, total: 0))
        #expect(!watchSyncing.canPractice)

        var cleared = keyring.state
        cleared.watchCopiesPending = nil
        keyring.save(cleared)
        let watchReady = try #require(keyring.snapshot.devices.first { $0.id == watchDevice.keyID })
        #expect(watchReady.readiness == .ready)
        #expect(watchReady.canPractice)

        var selfTest = Agentkeyring_V2_WatchSelfTest()
        selfTest.passcodeSet = true
        selfTest.notificationsAllowed = true
        selfTest.pushAddress = true
        selfTest.practiceAnswered = true
        keyring.watchTested(selfTest)
        #expect(keyring.snapshot.watch.notificationsAllowed)
        #expect(keyring.snapshot.watch.pushAddress)
        #expect(keyring.snapshot.watch.practiceAnswered)
    }
}

@Test("An unknown protobuf first-run stage preserves other saved state")
func unknownFirstRunStagePreservesSavedState() throws {
    var saved = PhoneSavedState()
    saved.deviceKeyID = "phone"
    saved.firstRun = .finished
    let encoded = try saved.encodeProtobuf()
    #expect(try PhoneSavedState.decodeProtobuf(encoded).firstRun == .finished)

    var proto = saved.storedProto()
    proto.firstRun.stage = .UNRECOGNIZED(999)
    let unknownStageData = PhoneSavedState.protobufMagic + (try proto.serializedData())
    let old = try PhoneSavedState.decodeProtobuf(unknownStageData)
    #expect(old.deviceKeyID == "phone")
    #expect(old.firstRun == nil)

    saved.firstRun = nil
    #expect(try PhoneSavedState.decodeProtobuf(saved.encodeProtobuf()).firstRun == nil)
}

@Suite("iPhone protobuf persistence and enrolment boundaries")
struct PhonePersistenceAndEnrolmentTests {
    @Test("PhoneSavedState protobuf round-trip preserves Data, Date, and pendingComputerDelivery")
    @MainActor func phoneSavedStateProtobufRoundTrip() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var original = PhoneSavedState()
        original.deviceKeyID = "phone-key-1"
        original.members = Data([1, 2, 3, 4])
        original.cloudAcceptedMembers = Data([5, 6, 7])
        original.catalogue = Data([8, 9])
        original.cloudAcceptedCatalogue = Data([10, 11])
        original.copies = Data([12, 13])
        original.requestEnvelopes = ["req-1": Data([14, 15])]
        original.answered = [:]
        original.firstRun = .practiceWaiting(id: "p9", arrived: true)
        original.pushSeen = true
        original.watchSelfTest = Data([16])
        original.watchDevice = Data([17])
        original.watchPush = Data([18])
        var settings = NotificationSettings()
        settings.timeSensitive = false
        settings.quietHours = true
        settings.quietFrom = 1320
        settings.quietTo = 420
        original.settings = settings
        original.lastPracticeReply = "Wait until tomorrow"
        original.watchCopiesPending = "watch-1"
        original.membersHistory = [Data([19]), Data([20])]
        original.pushRegistrations = ["phone-key-1": Data([21])]
        original.ownVaultSnapshot = Data([23, 24])
        original.sealedForOthers = Data([25])
        original.copiedAt = Date(timeIntervalSince1970: 1_700_000_123.5)
        original.remindToUpdate = true
        original.invitation = Data([26])
        original.deviceJoin = PendingDeviceJoin(device: Data([27]), machine: Data([28]), asked: Date(timeIntervalSince1970: 1_700_000_200.25))
        original.mailboxes = ["m1": Data([29])]
        original.watchCopiesSent = 7
        original.watchCopiesHeld = 6
        original.watchCopiesFromOthers = Data()
        original.pendingComputerDelivery = PendingComputerDelivery(
            joinRequest: Data([30, 31]),
            joinSecret: Data(repeating: 0xAA, count: 16),
            relayURL: "https://relay.example",
            machineID: "machine-1",
            machineLabel: "Linux Box",
            statusPayload: Data([32, 33, 34]),
            expiresAt: Date(timeIntervalSince1970: 1_700_001_000.5),
            mailbox: Data([35, 36])
        )

        let pbDecoded = try PhoneSavedState.decodeProtobuf(original.encodeProtobuf())
        #expect(pbDecoded == original)
        #expect(pbDecoded.watchCopiesFromOthers == Data())

        try original.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let reloaded = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: SoftwarePhoneKeys(),
                                    identity: { throw CancellationError() })
        #expect(reloaded.state == original)
    }

    @Test("Watch enrolment failure after membership commit stays in enrolledDeliveryPending and retries without duplicate Watch")
    @MainActor func watchEnrollmentCommitBoundaryAndRetry() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let phoneKeys = OpeningCapablePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())

        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [phoneDevice]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        let loginID = UUID().uuidString
        var login = Agentkeyring_V2_Login()
        login.loginID = loginID
        login.title = "example.com"
        login.sites = ["example.com"]
        login.account = "you@example.com"
        login.rule = .ask
        login.version = 10
        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = 1
        catalogue.logins = [login]
        let signedCatalogue = try CredentialSealing.signedDocument(catalogue.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        var secret = LoginSecret()
        secret.loginID = loginID
        secret.title = "example.com"
        secret.sites = ["example.com"]
        secret.username = "you@example.com"
        secret.password = "pw"
        let ownCopy = try CredentialSealing.sealLogin(
            secret,
            version: 10,
            to: phoneKeys.opening.publicKey,
            openerID: phoneKeyID,
            signer: PayloadReplySigner(keyID: phoneDevice.replyKeyID, sign: phoneKeys.signReply)
        )
        var ownBatch = Agentkeyring_V2_SealedLogins()
        ownBatch.logins = [ownCopy]

        var saved = PhoneSavedState()
        saved.deviceKeyID = phoneKeyID
        saved.members = try signedMembers.serializedData()
        saved.catalogue = try signedCatalogue.serializedData()
        saved.copies = try ownBatch.serializedData()
        saved.firstRun = .finished
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let keyring = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: phoneKeys,
                                   identity: { throw CancellationError() })
        keyring.watchPairing(paired: true, installed: true)
        await keyring.handleAddWatchTap(.open)
        await keyring.handleAddWatchTap(.continueWithFaceID)
        let offerID = try #require(keyring.activeWatchOfferID)

        let watchSigning = P256.Signing.PrivateKey()
        let watchOpening = P256.KeyAgreement.PrivateKey()
        let watchReply = P256.Signing.PrivateKey()
        let watchKeyID = CredentialSealing.keyID(watchSigning.publicKey.x963Representation)
        var watchDevice = Agentkeyring_V2_Device()
        watchDevice.keyID = watchKeyID
        watchDevice.kind = .watch
        watchDevice.label = "Apple Watch"
        watchDevice.signingPublicKey = watchSigning.publicKey.x963Representation
        watchDevice.openingPublicKey = watchOpening.publicKey.x963Representation
        watchDevice.replyPublicKey = watchReply.publicKey.x963Representation
        watchDevice.replyKeyID = CredentialSealing.keyID(watchReply.publicKey.x963Representation)

        // First attempt: onWatchCopies is nil so copy delivery fails immediately AFTER Members commit.
        #expect(keyring.watchOffered(device: try watchDevice.serializedData(), push: nil, offerID: offerID))
        for _ in 0..<80 {
            if case .copiesFailed = keyring.addWatchFlow { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .copiesFailed = keyring.addWatchFlow else {
            Issue.record("Expected copiesFailed after Watch delivery failure, got \(String(describing: keyring.addWatchFlow))")
            return
        }
        let committedRevision = keyring.members?.revision
        #expect(committedRevision == 2)
        #expect(keyring.members?.devices.filter { $0.kind == .watch }.count == 1)
        #expect(keyring.watchCopiesPending)
        #expect(keyring.watchEnrollment.isEnrolledDeliveryPending)
        #expect(!keyring.cancelWatchOffer(offerID: offerID))
        await keyring.handleAddWatchTap(.cancel)
        #expect(keyring.watchCopiesPending)
        #expect(keyring.watchEnrollment.isEnrolledDeliveryPending)

        // Retry with valid hold finishes delivery without re-publishing Members or adding a second Watch.
        keyring.onWatchCopies = { _, generation in
            Task { @MainActor in keyring.watchHolds(copiesGeneration: generation) }
        }
        await keyring.handleAddWatchTap(.tryAgain)
        for _ in 0..<80 where keyring.addWatchFlow != .added {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(keyring.addWatchFlow == .added)
        #expect(keyring.members?.revision == committedRevision)
        #expect(keyring.members?.devices.filter { $0.kind == .watch }.count == 1)
        #expect(!keyring.watchCopiesPending)
    }

    @Test("Computer join delivery failure persists pendingComputerDelivery and retries without bumping Members, with the whole mailbox even after a restart lost it",
          arguments: [false, true])
    @MainActor func computerJoinDeliveryFailureAndRetry(mailboxLostInRestart: Bool) async throws {
        MemoryRelay.install()

        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let phoneKeys = OpeningCapablePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())

        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [phoneDevice]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        let loginID = UUID().uuidString
        var login = Agentkeyring_V2_Login()
        login.loginID = loginID
        login.title = "auto.example"
        login.sites = ["auto.example"]
        login.account = "bot@auto.example"
        login.rule = .automatic
        login.version = 5
        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = 1
        catalogue.logins = [login]
        let signedCatalogue = try CredentialSealing.signedDocument(catalogue.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        var secret = LoginSecret()
        secret.loginID = loginID
        secret.title = "auto.example"
        secret.sites = ["auto.example"]
        secret.username = "bot@auto.example"
        secret.password = "pw-auto"
        let ownCopy = try CredentialSealing.sealLogin(
            secret,
            version: 5,
            to: phoneKeys.opening.publicKey,
            openerID: phoneKeyID,
            signer: PayloadReplySigner(keyID: phoneDevice.replyKeyID, sign: phoneKeys.signReply)
        )
        var ownBatch = Agentkeyring_V2_SealedLogins()
        ownBatch.logins = [ownCopy]

        var saved = PhoneSavedState()
        saved.deviceKeyID = phoneKeyID
        saved.members = try signedMembers.serializedData()
        saved.catalogue = try signedCatalogue.serializedData()
        saved.copies = try ownBatch.serializedData()
        saved.firstRun = .finished
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let keyring = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: phoneKeys,
                                   identity: { throw CancellationError() })

        let machineTLS = P256.Signing.PrivateKey()
        let machineRecv = P256.KeyAgreement.PrivateKey()
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = CredentialSealing.keyID(machineTLS.publicKey.derRepresentation)
        machine.label = "Build Box"
        machine.tlsPublicKey = machineTLS.publicKey.derRepresentation
        machine.receivingPublicKey = machineRecv.publicKey.x963Representation

        let code = ComputerJoinCode.make(relay: MemoryRelay.url)
        var joinRequest = Agentkeyring_V2_JoinRequest()
        joinRequest.machine = machine
        joinRequest.challenge = Data(repeating: 0x42, count: 16)
        joinRequest.proof = CredentialSealing.joinProof(secret: code.keys.proof, joining: joinRequest)

        // The relay fails writes to the join's answer box until it recovers.
        let responseBox = code.keys.responseBox
        MemoryRelay.setIntercept(for: responseBox) { request in request.httpMethod == "PUT" ? (403, Data(), [:]) : nil }
        defer { MemoryRelay.setIntercept(for: responseBox, handler: nil) }
        let relay = try #require(RelayBoxClient(checking: MemoryRelay.url))
        keyring.computerJoin = (joinRequest, code.secret, code.keys, relay, .now.addingTimeInterval(600))
        keyring.addComputerFlow = .asked(name: machine.label)

        await keyring.approveComputer()

        #expect(keyring.members?.revision == 2)
        #expect(keyring.members?.machines.contains(where: { $0.machineID == machine.machineID }) == true)
        #expect(keyring.madeForOthers.contains(where: { $0.openerID == machine.machineID }) == true)
        #expect(keyring.addComputerFlow == .deliveryFailed(name: machine.label, reason: PhoneCopy.addComputerDeliveryFailed))
        let pending = try #require(keyring.state.pendingComputerDelivery)
        #expect(pending.machineID == machine.machineID)

        let kept = try #require(keyring.state.mailboxes[machine.machineID])
        #expect(pending.mailbox == kept)
        if mailboxLostInRestart {
            let stateFile = directory.appending(path: "phone-v2.pb")
            var onDisk = try PhoneSavedState.decodeProtobuf(Data(contentsOf: stateFile))
            onDisk.mailboxes = [:]
            try onDisk.encodeProtobuf().write(to: stateFile)
        }

        // The relay recovers; the app is relaunched and retries at the same relay.
        MemoryRelay.setIntercept(for: responseBox, handler: nil)

        let relaunched = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: phoneKeys,
                                      identity: { throw CancellationError() })
        await relaunched.handleAddComputerTap(.open)
        #expect(relaunched.addComputerFlow == .deliveryFailed(name: machine.label, reason: PhoneCopy.addComputerDeliveryFailed))
        await relaunched.handleAddComputerTap(.retryDelivery)

        #expect(relaunched.members?.revision == 2)
        #expect(relaunched.state.pendingComputerDelivery == nil)
        #expect(relaunched.addComputerFlow == .added(name: machine.label))

        let response = try #require(try await relay.fetchRelayBox(box: responseBox, key: code.keys.responseKey))
        let status = try Agentkeyring_V2_JoinStatus(serializedBytes: response.message)
        #expect(status.state == .approved)
        #expect(status.bundle.copies.contains { $0.openerID == machine.machineID && $0.loginID == loginID })
        // The iPhone keeps the writer; the computer is given only the read side.
        #expect(relaunched.state.mailboxes[machine.machineID] == kept)
        let whole = try Agentkeyring_V2_UpdateMailbox(serializedBytes: kept)
        #expect(!whole.writeAuth.isEmpty && status.mailbox.readAuth == whole.readAuth && status.mailbox.writeAuth.isEmpty)
    }
}

/// Keys that are never reached: an answered request needs none.
@MainActor struct NoKeys: PhoneDeviceKeys {
    struct Unused: Error {}
    func signingPublicKey() throws -> Data { throw Unused() }
    func openingPublicKey() throws -> Data { throw Unused() }
    func replyPublicKey() throws -> Data { throw Unused() }
    func noticePublicKey() throws -> Data { throw Unused() }
    func authorize(_ context: LAContext, reason: String) async throws { throw Unused() }
    func signWithDeviceKey(_ bytes: Data, context: LAContext) throws -> Data { throw Unused() }
    func openSealedLogin(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { throw Unused() }
    func signReply(_ bytes: Data) throws -> Data { throw Unused() }
    func replySigner() throws -> @Sendable (Data) throws -> Data { throw Unused() }
    func opener(context: LAContext) throws -> @Sendable (SealedLogin) throws -> LoginSecret { throw Unused() }
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope { throw Unused() }
    func cloudKeyOpener() throws -> CloudEnvelope.KeyOpener { throw Unused() }
}
