// Written by AI on 2026.11.20 by model Claude Opus 5.5.
// The iPhone's notification names a practice notice with the practice words
// (on 20 Nov it showed the fallback "An agent wants to use a password."), and
// still refuses a computer's request that its computer did not sign.

@testable import AgentKeyringEngine
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@Suite("iPhone notification words")
struct PhoneNoticeTests {
    func envelope(_ build: (inout KeyringRequest) -> Void) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"; request.requestID = "r1"
        request.answerByUnixSeconds = Int64(Date().timeIntervalSince1970) + 600
        request.answerBoxID = String(repeating: "ab", count: 32)
        request.answerBoxKey = Data(repeating: 7, count: 32)
        build(&request)
        var envelope = Agentkeyring_V2_SignedRequestEnvelope()
        envelope.request = try request.serializedData()
        return envelope
    }

    @Test("A practice notice is named with the practice words")
    func practiceNotice() throws {
        let mac = P256.Signing.PrivateKey()
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = "mac"; machine.tlsPublicKey = mac.publicKey.derRepresentation
        var members = Members()
        members.machines = [machine]
        var practice = try envelope { $0.machineID = "mac"; $0.forDeviceKeyID = "phone" }
        practice.requestSignature = try mac.signature(for: practice.request).derRepresentation
        let named = try PhoneKeyringEngine.named(practice, members: members, catalogue: nil, keyID: "phone")
        #expect(named.request.login.site == PhoneCopy.practiceSite)
        #expect(named.request.agentReason == PhoneCopy.practiceReason)
    }

    @Test("A computer's request without its signature is not named")
    func unsignedRequest() throws {
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = "mini"; machine.tlsPublicKey = P256.Signing.PrivateKey().publicKey.derRepresentation
        var members = Members()
        members.machines = [machine]
        #expect(throws: PushNotificationDecodeError.self) {
            try PhoneKeyringEngine.named(envelope { $0.machineID = "mini"; $0.loginID = "example" }, members: members, catalogue: nil, keyID: "phone")
        }
    }

    /// On 20 Nov the relay recorded "approved by iPhone" and the app said "Your answer wasn't sent":
    /// the notification's Approve and the app's both ran, and the second was refused.
    @Test("A second Approve or Deny for a request this iPhone already answered is not an error")
    @MainActor func answeringTwice() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var answered = try envelope { $0.machineID = "mini"; $0.loginID = "example" }
        answered.outcome.state = .approved
        var saved = PhoneSavedState()
        saved.deviceKeyID = "phone"
        saved.requestEnvelopes = ["r1": try answered.serializedData()]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))
        let backend = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: NoKeys(),
                                   identity: { throw CancellationError() })
        try await backend.approveAccessRequest("r1", reusingUnlock: false)
        try await backend.denyAccessRequest("r1", reply: nil)
    }

    @Test("Answer It Here saves the practice request envelope across relaunch without faking push arrival")
    @MainActor func practiceSavesEnvelopeWithoutFakingArrivalAndReusesOnRelaunch() async throws {
        MemoryRelay.install()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let keys = SoftwarePhoneKeys()
        let keyID = try CredentialSealing.keyID(keys.signingPublicKey())
        var device = Agentkeyring_V2_Device()
        device.keyID = keyID
        device.kind = .iphone
        device.label = "iPhone"
        device.signingPublicKey = try keys.signingPublicKey()
        device.noticePublicKey = try keys.noticePublicKey()
        device.openingPublicKey = try keys.openingPublicKey()
        device.replyPublicKey = try keys.replyPublicKey()
        device.replyKeyID = try CredentialSealing.keyID(keys.replyPublicKey())
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [device]
        var signedMembers = SignedDocument()
        signedMembers.payload = try members.serializedData()

        var registration = Agentkeyring_V2_PushRegistration()
        registration.domain = "agentkeyring.push.v2"
        registration.deviceKeyID = keyID
        registration.apnsToken = Data(repeating: 0xAB, count: 32)
        registration.apnsTopic = "com.joshpalmer.AgentKeyring.Phone"
        registration.apnsProduction = false
        registration.noticePublicKey = try keys.noticePublicKey()
        var signedReg = SignedDocument()
        signedReg.payload = try registration.serializedData()

        var saved = PhoneSavedState()
        saved.deviceKeyID = keyID
        saved.members = try signedMembers.serializedData()
        saved.pushRegistrations = [keyID: try signedReg.serializedData()]
        saved.firstRun = .practiceOffer
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let pushConfig = URLSessionConfiguration.ephemeral
        pushConfig.protocolClasses = [StubPushProtocol.self]
        let pushSession = URLSession(configuration: pushConfig)

        let first = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: keys,
                                 identity: { throw CancellationError() })
        first.pusher = ApplePush(relayURL: URL(string: "https://push.test")!, session: pushSession)
        first.pushState = .registered

        // Send practice request: signed request envelope is saved locally (for Answer It Here on timeout),
        // but firstRun stays waiting (arrived == false) until a real push arrives.
        await first.sendFirstRunEvent(.sendPractice(id: "p1"))
        for _ in 0..<40 where first.practiceEnvelope("p1") == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let firstEnvelope = try #require(first.practiceEnvelope("p1"))
        #expect(first.snapshot.firstRun == PhoneFirstRun.practiceWaiting(id: "p1", arrived: false))

        // If no push arrives within 30s, timeout reaches practiceNotArrived with signed request envelope ready for Answer It Here.
        await first.sendFirstRunEvent(.practiceTimedOut(pushAddress: true))
        #expect(first.snapshot.firstRun == PhoneFirstRun.practiceNotArrived(id: "p1"))
        #expect(first.practiceEnvelope("p1")?.request == firstEnvelope.request)
        first.stopBackgroundWork()

        // Simulate force-quit + relaunch: practiceAsks is empty in memory, so originatePractice
        // must reuse the exact saved signed request envelope (same request bytes and answer box) rather than making a new one.
        let relaunched = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: keys,
                                      identity: { throw CancellationError() })
        relaunched.pusher = ApplePush(relayURL: URL(string: "https://push.test")!, session: pushSession)
        relaunched.pushState = .registered
        #expect(relaunched.snapshot.firstRun == PhoneFirstRun.practiceWaiting(id: "p1", arrived: false))

        let returnedID = try await relaunched.originatePractice(for: keyID, id: "p1")
        #expect(returnedID == "p1")
        let relaunchedEnvelope = try #require(relaunched.practiceEnvelope("p1"))
        #expect(relaunchedEnvelope.request == firstEnvelope.request)
        #expect(relaunched.snapshot.firstRun == PhoneFirstRun.practiceWaiting(id: "p1", arrived: false))

        // Only a real push (via receive) marks the practice request as arrived.
        #expect(relaunched.receive(relaunchedEnvelope, allowRefresh: false))
        #expect(relaunched.snapshot.firstRun == PhoneFirstRun.practice(id: "p1"))
        relaunched.stopBackgroundWork()
    }

    @Test("Locked background push token stays pending on -25308, finishes registering on start() once unlocked, and resumes practice")
    @MainActor func lockedPushTokenStaysPendingAndCompletesOnUnlock() async throws {
        MemoryRelay.install()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let keys = SoftwarePhoneKeys()
        let keyID = try CredentialSealing.keyID(keys.signingPublicKey())
        var device = Agentkeyring_V2_Device()
        device.keyID = keyID
        device.kind = .iphone
        device.label = "iPhone"
        device.signingPublicKey = try keys.signingPublicKey()
        device.noticePublicKey = try keys.noticePublicKey()
        device.openingPublicKey = try keys.openingPublicKey()
        device.replyPublicKey = try keys.replyPublicKey()
        device.replyKeyID = try CredentialSealing.keyID(keys.replyPublicKey())
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [device]
        var signedMembers = SignedDocument()
        signedMembers.payload = try members.serializedData()

        // Stale sandbox registration persisted from an earlier dev build.
        var staleReg = Agentkeyring_V2_PushRegistration()
        staleReg.domain = "agentkeyring.push.v2"
        staleReg.deviceKeyID = keyID
        staleReg.apnsToken = Data(repeating: 0x11, count: 32)
        staleReg.apnsTopic = "com.joshpalmer.AgentKeyring.Phone"
        staleReg.apnsProduction = false
        staleReg.noticePublicKey = try keys.noticePublicKey()
        var signedStale = SignedDocument()
        signedStale.payload = try staleReg.serializedData()

        var saved = PhoneSavedState()
        saved.deviceKeyID = keyID
        saved.members = try signedMembers.serializedData()
        saved.pushRegistrations = [keyID: try signedStale.serializedData()]
        saved.firstRun = .practiceWaiting(id: "p2", arrived: false)
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let pushConfig = URLSessionConfiguration.ephemeral
        pushConfig.protocolClasses = [StubPushProtocol.self]
        let pushSession = URLSession(configuration: pushConfig)

        let backend = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: keys,
                                   identity: { throw CancellationError() })
        backend.pusher = ApplePush(relayURL: URL(string: "https://push.test")!, session: pushSession)

        // App wakes while locked: Apple delivers the production token, signing throws -25308,
        // and PhoneKeyringEngine holds the token in .pending instead of discarding it.
        keys.locked = true
        let prodToken = Data(repeating: 0x22, count: 32)
        await #expect(throws: Error.self) {
            try await backend.registerPush(token: prodToken, topic: "com.joshpalmer.AgentKeyring.Phone", production: true)
        }
        #expect(backend.pushState == .pending(token: prodToken, topic: "com.joshpalmer.AgentKeyring.Phone", production: true))
        #expect(!backend.pushRegistered)

        // Timing out while pending must move to settingUpNotifications WITHOUT pushing to the stale sandbox token.
        await backend.sendFirstRunEvent(.practiceTimedOut(pushAddress: false))
        try await Task.sleep(for: .milliseconds(50))
        #expect(backend.snapshot.firstRun == PhoneFirstRun.settingUpNotifications(id: "p2"))
        #expect(backend.practiceEnvelope("p2") == nil)

        // User unlocks and opens the app: start() completes the pending registration without asking Apple again
        // and automatically sends the waiting practice request using the fresh production token.
        keys.locked = false
        backend.startBackgroundWork()
        for _ in 0..<40 where backend.practiceEnvelope("p2") == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(backend.pushState == .registered)
        #expect(backend.pushRegistration(for: keyID)?.apnsProduction == true)
        #expect(backend.pushRegistration(for: keyID)?.apnsToken == prodToken)
        #expect(backend.practiceEnvelope("p2") != nil)
        backend.stopBackgroundWork()
    }

    @Test("Delivered notification on launch never auto-pops practice sheet, and answering own practice settles immediately")
    @MainActor func deliveredNotificationStaysCalmAndOwnPracticeSettlesImmediately() async throws {
        MemoryRelay.install()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let keys = SoftwarePhoneKeys()
        let keyID = try CredentialSealing.keyID(keys.signingPublicKey())
        var device = Agentkeyring_V2_Device()
        device.keyID = keyID
        device.kind = .iphone
        device.label = "iPhone"
        device.signingPublicKey = try keys.signingPublicKey()
        device.noticePublicKey = try keys.noticePublicKey()
        device.openingPublicKey = try keys.openingPublicKey()
        device.replyPublicKey = try keys.replyPublicKey()
        device.replyKeyID = try CredentialSealing.keyID(keys.replyPublicKey())
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [device]
        var signedMembers = SignedDocument()
        signedMembers.payload = try members.serializedData()

        var registration = Agentkeyring_V2_PushRegistration()
        registration.domain = "agentkeyring.push.v2"
        registration.deviceKeyID = keyID
        registration.apnsToken = Data(repeating: 0xCD, count: 32)
        registration.apnsTopic = "com.joshpalmer.AgentKeyring.Phone"
        registration.apnsProduction = true
        registration.noticePublicKey = try keys.noticePublicKey()
        var signedReg = SignedDocument()
        signedReg.payload = try registration.serializedData()

        var saved = PhoneSavedState()
        saved.deviceKeyID = keyID
        saved.members = try signedMembers.serializedData()
        saved.pushRegistrations = [keyID: try signedReg.serializedData()]
        saved.firstRun = .practiceWaiting(id: "p3", arrived: false)

        // Pre-save a self-originated practice request as if from before a force-quit (practiceAsks is empty).
        var envelope = try CredentialSealing.practiceRequest(id: "p3", for: keyID, by: keyID, signReply: keys.signReply)
        envelope.login = PhoneKeyringEngine.practiceLogin
        saved.requestEnvelopes = ["p3": try envelope.serializedData()]
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let backend = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: keys,
                                   identity: { throw CancellationError() })
        // Before notification settings or APNs token registration finish on cold launch,
        // reading a delivered notification from Notification Centre must NEVER auto-pop .practice(id).
        #expect(!backend.pushRegistered)
        #expect(!backend.snapshot.notificationFacts.allowed)
        #expect(backend.receive(envelope, allowRefresh: false, pushExpected: true))
        #expect(backend.snapshot.firstRun == .practiceWaiting(id: "p3", arrived: true))

        // Denying that practice request with an explanation immediately settles to .practiceResult(.denied)
        // with the reply intact, even with no active readPracticeBox poller.
        try await backend.denyAccessRequest("p3", reply: "Use the file in Downloads")
        #expect(backend.snapshot.firstRun == .practiceResult(.denied))
        #expect(backend.snapshot.practiceDeniedReply == "Use the file in Downloads")

        // Sending and approving a fresh practice request also settles immediately to .practiceResult(.approved).
        var work4 = try CredentialSealing.practiceRequest(id: "p4", for: keyID, by: keyID, signReply: keys.signReply)
        work4.login = PhoneKeyringEngine.practiceLogin
        await backend.sendFirstRunEvent(.sendPractice(id: "p4"))
        #expect(backend.receive(work4, allowRefresh: false, pushExpected: true))
        #expect(backend.snapshot.firstRun == .practiceWaiting(id: "p4", arrived: true))
        try await backend.approveAccessRequest("p4", reusingUnlock: false)
        #expect(backend.snapshot.firstRun == .practiceResult(.approved))
        backend.stopBackgroundWork()
    }

    @Test("Batch setRule(_:forLogins:) updates multiple logins in one revision, and PhoneModel uses it")
    @MainActor func batchSetRuleUpdatesOneRevisionAndSealsAutomatic() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let phoneKeys = OpeningCapablePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        let machineTLS = P256.Signing.PrivateKey()
        let machineRecv = P256.KeyAgreement.PrivateKey()

        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())

        var machine = Agentkeyring_V2_Machine()
        machine.machineID = CredentialSealing.keyID(machineTLS.publicKey.derRepresentation)
        machine.label = "Linux Box"
        machine.tlsPublicKey = machineTLS.publicKey.derRepresentation
        machine.receivingPublicKey = machineRecv.publicKey.x963Representation

        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [phoneDevice]
        members.machines = [machine]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        let id1 = UUID().uuidString
        let id2 = UUID().uuidString
        func makeLogin(_ id: String, site: String, version: UInt64) -> (Agentkeyring_V2_Login, SealedLogin) {
            var login = Agentkeyring_V2_Login()
            login.loginID = id
            login.title = site
            login.sites = [site]
            login.account = "user@example.com"
            login.rule = .ask
            login.version = version
            var secret = LoginSecret()
            secret.loginID = id
            secret.title = site
            secret.sites = [site]
            secret.username = "user@example.com"
            secret.password = "pw-\(site)"
            let sealed = try! CredentialSealing.sealLogin(
                secret,
                version: version,
                to: phoneKeys.opening.publicKey,
                openerID: phoneKeyID,
                signer: PayloadReplySigner(keyID: phoneDevice.replyKeyID, sign: phoneKeys.signReply)
            )
            return (login, sealed)
        }
        let (l1, c1) = makeLogin(id1, site: "one.example", version: 10)
        let (l2, c2) = makeLogin(id2, site: "two.example", version: 20)

        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = 1
        catalogue.logins = [l1, l2]
        let signedCatalogue = try CredentialSealing.signedDocument(catalogue.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }
        var ownBatch = Agentkeyring_V2_SealedLogins()
        ownBatch.logins = [c1, c2]

        var saved = PhoneSavedState()
        saved.deviceKeyID = phoneKeyID
        saved.members = try signedMembers.serializedData()
        saved.catalogue = try signedCatalogue.serializedData()
        saved.copies = try ownBatch.serializedData()
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let keyring = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: phoneKeys,
                                   identity: { throw CancellationError() })
        try await keyring.setLoginRule(.automatic, forLogins: [id1, id2])

        #expect(keyring.catalogue?.revision == 2)
        #expect(keyring.catalogue?.logins.allSatisfy { $0.rule == .automatic } == true)
        let machineCopies = keyring.madeForOthers.filter { $0.openerID == machine.machineID }
        #expect(Set(machineCopies.map(\.loginID)) == Set([id1, id2]))

        // Dumped for the sandbox, both logins keep their new rule, and neither keeps its password.
        let bundle = try keyring.sandboxBundle()
        let dumped = try PhoneKeyringEngine.sandboxState(from: bundle)
        #expect(Set(dumped.logins.map(\.id)) == Set([id1, id2]))
        #expect(dumped.logins.allSatisfy { $0.rule == .automatic && $0.password == SandboxSecrets.password })
        #expect(dumped.thisDeviceID == phoneKeyID)
        #expect(dumped.phone.firstRun == keyring.snapshot.firstRun)

        // PhoneModel.confirmRuleChange changes every picked login under one approval, and a failed one says so.
        var state = SandboxState.builtIn()
        state.logins = [SandboxLogin(id: id1, site: "one.example", account: "", rule: .ask),
                        SandboxLogin(id: id2, site: "two.example", account: "", rule: .ask)]
        let world = SandboxWorld(state)
        let model = PhoneModel(backend: world, initial: world.phoneSnapshot)
        model.beginEditingRules()
        model.toggleEditSelection(id1)
        model.toggleEditSelection(id2)
        model.requestRuleChange(.blocked)
        #expect(model.ruleConfirmation?.plan.willDeleteSecretsCount == 2)
        await model.confirmRuleChange()
        #expect(world.effects.ran == [.setRule])
        #expect(world.state.logins.allSatisfy { $0.rule == .blocked && $0.secretDeleted })
        #expect(model.failure == nil)

        world.effects.outcomes[.setRule] = .fail("Offline")
        model.applySnapshot(world.phoneSnapshot)
        model.beginEditingRules()
        model.toggleEditSelection(id1)
        model.requestRuleChange(.ask)
        await model.confirmRuleChange()
        #expect(model.failure == PhoneCopy.changeFailed)
        #expect(world.state.logins.first { $0.id == id1 }?.rule == .blocked)
    }

    @Test("Delayed approval notice cannot resurrect an ended request on iPhone")
    @MainActor func delayedApprovalCannotResurrectEndedRequest() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let phoneKeys = SoftwarePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        let machineKey = P256.Signing.PrivateKey()
        let machineID = CredentialSealing.keyID(machineKey.publicKey.derRepresentation)

        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())

        var machine = Agentkeyring_V2_Machine()
        machine.machineID = machineID
        machine.label = "Mac mini"
        machine.tlsPublicKey = machineKey.publicKey.derRepresentation
        machine.receivingPublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation

        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [phoneDevice]
        members.machines = [machine]
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: phoneKeyID) {
            try phoneKeys.signWithDeviceKey($0, context: LAContext())
        }

        var saved = PhoneSavedState()
        saved.deviceKeyID = phoneKeyID
        saved.members = try signedMembers.serializedData()
        try saved.encodeProtobuf().write(to: directory.appending(path: "phone-v2.pb"))

        let keyring = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: phoneKeys,
                                   identity: { throw CancellationError() })
        var endedEnvelope = try envelope { $0.machineID = machineID; $0.loginID = "login-1" }
        endedEnvelope.requestSignature = try machineKey.signature(for: endedEnvelope.request).derRepresentation
        endedEnvelope.outcome.state = .ended
        #expect(keyring.receive(endedEnvelope, allowRefresh: false))

        var lateApproved = endedEnvelope
        lateApproved.outcome.state = .approved
        lateApproved.outcome.notAfterUnixSeconds = Int64(Date().timeIntervalSince1970) + 1800
        #expect(keyring.receive(lateApproved, allowRefresh: false))

        let stored = try #require(keyring.state.requestEnvelopes["r1"].flatMap { try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) })
        #expect(stored.outcome.state == .ended)
    }

    @Test("A denial survives relaunch only after the relay accepts it")
    @MainActor
    func answerSurvivesRelaunchAfterDelivery() async throws {
        MemoryRelay.install()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let phone = answeringPhone(directory)
        defer { phone.stopBackgroundWork() }
        let machineKey = P256.Signing.PrivateKey()
        var machine = Agentkeyring_V2_Machine()
        machine.tlsPublicKey = machineKey.publicKey.derRepresentation
        machine.machineID = CredentialSealing.keyID(machine.tlsPublicKey)
        var members = Members()
        members.machines = [machine]
        var signedMembers = SignedDocument()
        signedMembers.payload = try members.serializedData()

        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"
        request.requestID = UUID().uuidString
        request.machineID = machine.machineID
        request.loginID = UUID().uuidString
        request.askedUnixSeconds = Int64(Date().timeIntervalSince1970)
        request.answerByUnixSeconds = request.askedUnixSeconds + 60
        request.answerBoxURL = MemoryRelay.url
        request.answerBoxID = CredentialSealing.keyID(Data(request.requestID.utf8))
        request.answerBoxKey = Data(repeating: 7, count: 32)
        var envelope = Agentkeyring_V2_SignedRequestEnvelope()
        envelope.request = try request.serializedData()
        envelope.requestSignature = try machineKey.signature(for: envelope.request).derRepresentation
        var saved = PhoneSavedState()
        saved.deviceKeyID = "phone"
        saved.members = try signedMembers.serializedData()
        saved.requestEnvelopes[request.requestID] = try envelope.serializedData()
        try #require(phone.save(saved))

        let (uploads, startedUpload) = AsyncStream<Void>.makeStream()
        let releaseResponse = DispatchSemaphore(value: 0)
        MemoryRelay.setIntercept(for: request.answerBoxID) { _ in
            startedUpload.yield(())
            guard releaseResponse.wait(timeout: .now() + 5) == .success else { return (403, Data(), [:]) }
            return (201, Data(), [:])
        }
        defer {
            releaseResponse.signal()
            MemoryRelay.setIntercept(for: request.answerBoxID, handler: nil)
        }
        let requestID = request.requestID
        let answer = Task {
            defer { startedUpload.finish() }
            try await phone.denyAccessRequest(requestID, reply: nil)
        }
        var uploadsIterator = uploads.makeAsyncIterator()
        let uploadStarted = await uploadsIterator.next() != nil
        try #require(uploadStarted)

        let interrupted = answeringPhone(directory)
        #expect(phone.settled(requestID))
        #expect(phone.snapshot.requests.first { $0.id == requestID }?.state == .sendingAnswer(.deny))
        #expect(!interrupted.settled(requestID))
        #expect(try interrupted.loadRequestEnvelope(requestID) == envelope)
        let diskDuringUpload = try PhoneSavedState.decodeProtobuf(Data(contentsOf: phone.stateURL))
        #expect(diskDuringUpload.answered[requestID] == nil)

        releaseResponse.signal()
        try await answer.value
        let relaunched = answeringPhone(directory)
        #expect(relaunched.settled(requestID))
        #expect(relaunched.state.answered[requestID] == false)
    }

    @MainActor
    private func answeringPhone(_ directory: URL) -> PhoneKeyringEngine {
        PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: NoKeys(),
                           identity: { throw CancellationError() })
    }
}

@MainActor final class OpeningCapablePhoneKeys: PhoneDeviceKeys {
    let signing = P256.Signing.PrivateKey()
    let opening = P256.KeyAgreement.PrivateKey()
    let reply = P256.Signing.PrivateKey()
    let notice = P256.KeyAgreement.PrivateKey()
    func signingPublicKey() throws -> Data { signing.publicKey.x963Representation }
    func openingPublicKey() throws -> Data { opening.publicKey.x963Representation }
    func replyPublicKey() throws -> Data { reply.publicKey.x963Representation }
    func noticePublicKey() throws -> Data { notice.publicKey.x963Representation }
    func authorize(_ context: LAContext, reason: String) async throws {}
    func signWithDeviceKey(_ bytes: Data, context: LAContext) throws -> Data { try signing.signature(for: bytes).derRepresentation }
    func openSealedLogin(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { try CredentialSealing.openSealedLogin(sealed, with: opening) }
    func signReply(_ bytes: Data) throws -> Data { try reply.signature(for: bytes).derRepresentation }
    func replySigner() throws -> @Sendable (Data) throws -> Data {
        let key = reply
        return { try key.signature(for: $0).derRepresentation }
    }
    func opener(context: LAContext) throws -> @Sendable (SealedLogin) throws -> LoginSecret {
        let key = opening
        return { try CredentialSealing.openSealedLogin($0, with: key) }
    }
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        try CredentialSealing.openNotice(notice, deviceKeyID: deviceKeyID, with: self.notice)
    }
    func cloudKeyOpener() throws -> CloudEnvelope.KeyOpener {
        let key = notice
        return { try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: key) }
    }
}

@MainActor final class SoftwarePhoneKeys: PhoneDeviceKeys {
    var locked = false
    let signing = P256.Signing.PrivateKey()
    let opening = P256.KeyAgreement.PrivateKey()
    let reply = P256.Signing.PrivateKey()
    let notice = P256.KeyAgreement.PrivateKey()
    func signingPublicKey() throws -> Data { signing.publicKey.x963Representation }
    func openingPublicKey() throws -> Data { opening.publicKey.x963Representation }
    func replyPublicKey() throws -> Data { reply.publicKey.x963Representation }
    func noticePublicKey() throws -> Data { notice.publicKey.x963Representation }
    func authorize(_ context: LAContext, reason: String) async throws {}
    func signWithDeviceKey(_ bytes: Data, context: LAContext) throws -> Data { try signing.signature(for: bytes).derRepresentation }
    func openSealedLogin(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { throw NoKeys.Unused() }
    func signReply(_ bytes: Data) throws -> Data {
        if locked { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
        return try reply.signature(for: bytes).derRepresentation
    }
    func replySigner() throws -> @Sendable (Data) throws -> Data {
        let key = reply
        return { try key.signature(for: $0).derRepresentation }
    }
    func opener(context: LAContext) throws -> @Sendable (SealedLogin) throws -> LoginSecret { { _ in throw NoKeys.Unused() } }
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        try CredentialSealing.openNotice(notice, deviceKeyID: deviceKeyID, with: self.notice)
    }
    func cloudKeyOpener() throws -> CloudEnvelope.KeyOpener {
        let key = notice
        return { try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: key) }
    }
}

final class StubPushProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "push.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}
