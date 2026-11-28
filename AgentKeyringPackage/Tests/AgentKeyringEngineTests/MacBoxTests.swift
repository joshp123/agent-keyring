// Written by AI on 2026.11.24 by model claude opus 5.5, from the door's tests of 2026.11.21 (since deleted).
//
// The Mac with another computer, through boxes at the relay (MemoryRelay):
// the computer joins with a code and gets its Automatic passwords; its
// request is shown in the Mac's panel, approved there into its answer box,
// and stays for its 30 minutes so Stop on the Mac ends it. Every key is made
// up here; nothing reaches Apple, a real device or the keychain.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import AgentKeyringEngine

/// Another computer: its signing identity and the key approvals are sealed to.
private struct TestComputer {
    let tls: DeviceTLSIdentity
    let receiving = P256.KeyAgreement.PrivateKey()
    let machine: Agentkeyring_V2_Machine

    init(label: String) throws {
        tls = try DeviceTLSIdentity.ephemeral()
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = CredentialSealing.keyID(tls.publicKeySPKI)
        machine.label = label
        machine.tlsPublicKey = tls.publicKeySPKI
        machine.receivingPublicKey = receiving.publicKey.x963Representation
        self.machine = machine
    }

    /// A request for one password, signed by this computer, answered in a new box at the relay.
    @MainActor func request(_ loginID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        var request = Agentkeyring_V2_Request()
        request.domain = "agentkeyring.request.v2"
        request.requestID = MacSyncCoordinator.newID()
        request.loginID = loginID
        request.machineID = machine.machineID
        request.reason = "You asked me to download October's invoice."
        request.agent = "Codex"
        request.askedUnixSeconds = Int64(Date().timeIntervalSince1970)
        request.answerByUnixSeconds = request.askedUnixSeconds + 600
        request.answerBoxID = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        request.answerBoxKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        request.answerBoxURL = MemoryRelay.url
        var envelope = Agentkeyring_V2_SignedRequestEnvelope()
        envelope.request = try request.serializedData()
        envelope.requestSignature = try tls.signWithTLSKey(envelope.request)
        return envelope
    }
}

@MainActor
private func eventually(_ what: String, within seconds: Double = 10, _ check: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !check() {
        guard Date() < end else { Issue.record("Timed out waiting for \(what)"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// A Mac with these passwords, each sealed to it at version 3, and the relay in memory.
@MainActor
private func mac(_ logins: [(login: Agentkeyring_V2_Login, password: String)], folder: URL) async throws -> MacSyncCoordinator {
    MemoryRelay.install()
    let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
    let store = MacVaultFileStore(directory: folder.appending(path: "logins"))
    let leases = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases")))
    try await store.replaceSealed(try logins.map { login, password in
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = login.loginID
        secret.username = login.account
        secret.password = password
        secret.title = login.title
        secret.sites = login.sites
        return try CredentialSealing.sealLogin(secret, version: login.version, to: keys.openingPublicKey, openerID: keys.deviceKeyID, signer: keys.signer)
    })
    var environment = MacSyncEnvironment(storage: .memory())
    environment.invitationStore = .nowhere
    environment.relay = RelayBoxClient(checking: MemoryRelay.url)!
    environment.complaints = folder.appending(path: "complaints.pb")
    let listed = logins.map(\.login)
    return MacSyncCoordinator(keys: keys, store: store, leaseStore: leases, environment: environment) { listed }
}

private func login(_ site: String, rule: Agentkeyring_V2_Rule, version: UInt64 = 3) -> Agentkeyring_V2_Login {
    var login = Agentkeyring_V2_Login()
    login.loginID = UUID().uuidString
    login.title = site
    login.sites = ["https://\(site)"]
    login.account = "you@\(site)"
    login.rule = rule
    login.version = version
    return login
}

@MainActor
@Suite(.serialized)
struct MacBoxTests {
    @Test func aComputerJoinsWithACodeAndGetsItsAutomaticPasswordsAtOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mac-code-join-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let automatic = login("auto.example.com", rule: .automatic)
        let ask = login("ask.example.com", rule: .ask)
        let mac = try await mac([(automatic, "auto-secret"), (ask, "ask-secret")], folder: folder)
        let relay = RelayBoxClient(checking: MemoryRelay.url)!

        // The computer puts its join in the code's request box, proving the code.
        let keys = try mac.machineInvite().code.keys
        let computer = try TestComputer(label: "New Linux Box")
        var join = Agentkeyring_V2_JoinRequest()
        join.machine = computer.machine
        join.challenge = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        join.proof = CredentialSealing.joinProof(secret: keys.proof, joining: join)
        try await relay.putRelayBox(join.serializedData(), box: keys.requestBox, key: keys.requestKey)
        try await eventually("the computer's join to show") { mac.joins.contains { MacSyncCoordinator.joinID($0) == computer.machine.machineID } }
        try await mac.approveJoin(computer.machine.machineID, context: LAContext(), onAuthenticated: {})

        var answer: FetchedBoxMessage?
        for _ in 0..<100 where answer == nil {
            answer = try await relay.fetchRelayBox(box: keys.responseBox, key: keys.responseKey)
            if answer == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let status = try Agentkeyring_V2_JoinStatus(serializedBytes: try #require(answer).message)
        #expect(status.state == .approved && status.challenge == join.challenge)
        #expect(status.mailbox.machineID == computer.machine.machineID && status.mailbox.writeAuth.isEmpty)
        let sealed = try #require(status.bundle.copies.first)
        #expect(status.bundle.copies.count == 1, "only the Automatic password, never one that asks")
        #expect(sealed.loginID == automatic.loginID && sealed.openerID == computer.machine.machineID)
        #expect(try CredentialSealing.openSealedLogin(sealed, with: computer.receiving).password == "auto-secret")
    }

    /// He copied from Passwords and chose Not Now: a computer keeps its copies of the list it holds until he
    /// sends the changes, then gets the new ones.
    @Test func aComputerKeepsItsCopiesUntilTheChangesAreSent() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mac-resync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        final class Version: @unchecked Sendable { var value: UInt64 = 7 }
        let version = Version()
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let store = MacVaultFileStore(directory: folder.appending(path: "logins"))
        let leases = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases")))
        let computer = try TestComputer(label: "Test server")
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = UUID().uuidString
        secret.password = "correct horse"
        let loginID = secret.loginID
        func copy(_ number: UInt64, for opener: String, key: P256.KeyAgreement.PublicKey) throws -> Agentkeyring_V2_SealedLogin {
            try CredentialSealing.sealLogin(secret, version: number, to: key, openerID: opener, signer: keys.signer)
        }
        let mac = MacSyncCoordinator(keys: keys, store: store, leaseStore: leases, environment: MacSyncEnvironment(storage: .memory())) {
            var login = Agentkeyring_V2_Login()
            login.loginID = loginID
            login.rule = .automatic
            login.version = version.value
            return [login]
        }
        var members = Agentkeyring_V2_Members()
        members.devices = [keys.device]
        members.machines = [keys.machine, computer.machine]
        try await store.replaceSealed([try copy(7, for: keys.deviceKeyID, key: keys.openingPublicKey),
                                       try copy(7, for: computer.machine.machineID, key: computer.receiving.publicKey)])
        try await mac.publishMembers(members, context: LAContext())
        try await mac.publish(context: LAContext())

        // A copy from Passwords brought version 8; the computer's version 7 stays beside it.
        try await store.replaceSealed([try copy(8, for: keys.deviceKeyID, key: keys.openingPublicKey),
                                       try copy(7, for: computer.machine.machineID, key: computer.receiving.publicKey),
                                       try copy(8, for: computer.machine.machineID, key: computer.receiving.publicKey)])
        version.value = 8
        let notSent = await mac.bundle(for: computer.machine, holding: 0)
        #expect(notSent.copies.map(\.version) == [7], "Not Now: the computer keeps the list it holds")

        try await mac.publish(context: LAContext())
        let sent = await mac.bundle(for: computer.machine, holding: 0)
        #expect(sent.copies.map(\.version) == [8])
        #expect(try await store.sealed().filter { $0.openerID == computer.machine.machineID }.map(\.version) == [8],
                "the old copy goes once the changes are sent")
    }

    @Test func anotherComputersRequestIsApprovedHereAndCanBeStoppedHereForItsThirtyMinutes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-ask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let asked = login("example.com", rule: .ask, version: 7)
        let mac = try await mac([(asked, "correct horse")], folder: folder)
        let computer = try TestComputer(label: "Test server")
        var members = Agentkeyring_V2_Members()
        members.devices = [mac.keys.device]
        members.machines = [mac.keys.machine, computer.machine]
        try await mac.publishMembers(members, context: LAContext())
        try await mac.publish(context: LAContext())
        let relay = RelayBoxClient(checking: MemoryRelay.url)!

        // Pushed to this Mac: shown, waiting for Josh. A request no computer in the list signed is not.
        let first = try computer.request(asked.loginID)
        let request = try CredentialSealing.parseRequest(first.request)
        var forged = first
        forged.requestSignature = try TestComputer(label: "Someone else").tls.signWithTLSKey(first.request)
        #expect(mac.takeRemoteAsk(forged) != .taken)
        #expect(mac.remoteAsks.isEmpty)
        #expect(mac.takeRemoteAsk(first) == .taken)
        let shown = try #require(mac.remoteAsks[request.requestID])
        #expect(shown.state == .waiting && shown.computer.label == "Test server" && shown.login.account == "you@example.com")
        #expect(mac.waitingRemoteAsks.map(\.id) == [request.requestID])

        // Touch ID: the approval goes in the request's answer box and opens there to the password, for that computer only.
        let sent = try await mac.approveRemote(request.requestID, context: LAContext(), onAuthenticated: {})
        #expect(sent.state == .waiting && sent.answeredBy == "Test Mac")
        let picked = try #require(try await relay.fetchRelayBox(box: request.answerBoxID, key: request.answerBoxKey))
        let upload = try Agentkeyring_V2_AnswerUpload(serializedBytes: picked.message)
        var approval = Agentkeyring_V2_Approval()
        approval.request = first.request
        approval.answer = upload.answer
        approval.delivery = upload.delivery
        let delivered = try CredentialSealing.openDelivery(approval, members: try #require(mac.members), with: computer.receiving)
        #expect(delivered.password == "correct horse")

        // The computer's outcome push: approved for 30 minutes. It stays here all that time, and a late
        // "no answer" from the panel's own timer does not undo it.
        var approved = Agentkeyring_V2_Lease()
        approved.requestID = request.requestID
        approved.loginID = asked.loginID
        approved.state = .approved
        approved.answeredBy = "Test Mac"
        approved.notAfterUnixSeconds = delivered.notAfterUnixSeconds
        mac.endRemote(request.requestID, approved)
        #expect(mac.remoteAsks[request.requestID]?.state == .ended(approved) && mac.waitingRemoteAsks.isEmpty)
        #expect(MacSyncCoordinator.keptFor(approved, now: .now) > 29 * 60, "an approval stays for its 30 minutes, so Stop here works in them")
        var unanswered = approved
        unanswered.state = .unanswered
        mac.endRemote(request.requestID, unanswered)
        #expect(mac.remoteAsks[request.requestID]?.state == .ended(approved))

        // Stop here: the grant at the relay is marked stopped with this Mac's signed Stop, and the computer
        // refuses every use after.
        let stopped = try await mac.stopRemote(request.requestID)
        #expect(stopped.state == .ended && stopped.endedBy == "Test Mac")
        #expect(mac.remoteAsks[request.requestID]?.state == .ended(stopped))
        let grant = try await relay.readLeaseGrantBox(answerBox: request.answerBoxID, key: request.answerBoxKey, requestID: request.requestID)
        #expect(!grant.live)
        let end = try Agentkeyring_V2_EndRequest(serializedBytes: try Agentkeyring_V2_Signed(serializedBytes: try #require(grant.stop)).payload)
        #expect(end.requestID == request.requestID && end.deviceKeyID == mac.keys.deviceKeyID)
        #expect(MacSyncCoordinator.keptFor(stopped, now: .now) == MacSyncCoordinator.endedKeptFor)

        // Answered on the iPhone first: the outcome closes the panel, and a late Touch ID here is told how it ended.
        let second = try computer.request(asked.loginID)
        let secondID = try CredentialSealing.parseRequest(second.request).requestID
        #expect(mac.takeRemoteAsk(second) == .taken)
        var byPhone = Agentkeyring_V2_Lease()
        byPhone.requestID = secondID
        byPhone.state = .approved
        byPhone.answeredBy = "Test iPhone"
        mac.endRemote(secondID, byPhone)
        #expect(mac.waitingRemoteAsks.isEmpty)
        #expect(try await mac.approveRemote(secondID, context: LAContext(), onAuthenticated: {}) == byPhone)
    }

    @Test("The lease record and the Mac's saved state round-trip as protobuf; a lease record this build cannot decode starts again")
    func leaseRecordAndMacSavedRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lease-pb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let leaseDir = folder.appending(path: "leases")
        let persistence = LeasePersistence(directory: leaseDir)
        let store = CredentialLeaseStore(persistence: persistence)
        let recipient = try store.recipient().recipientID
        let pbFile = leaseDir.appending(path: "leases.pb")
        #expect(try Data(contentsOf: pbFile).starts(with: CredentialLeaseStore.Snapshot.protobufMagic))
        let reloaded = CredentialLeaseStore(persistence: persistence)
        #expect(try reloaded.recipient().recipientID == recipient)

        try Data("not a lease record".utf8).write(to: pbFile)
        let restarted = CredentialLeaseStore(persistence: persistence)
        try restarted.loadLeaseRecords()
        #expect(try restarted.recipient().recipientID != recipient)
        #expect(try Data(contentsOf: pbFile).starts(with: CredentialLeaseStore.Snapshot.protobufMagic))

        let storage = MacKeychainStateStore.memory()
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let device = MacSyncCoordinator(keys: keys, store: MacVaultFileStore(directory: folder.appending(path: "logins")),
                               leaseStore: reloaded, environment: MacSyncEnvironment(storage: storage)) { [] }
        device.saved.catalogueRevision = 9
        device.saved.copiesRevision = 4
        device.persist()
        let persisted = try #require(storage.read("saved"))
        #expect(persisted.starts(with: MacSyncCoordinator.savedProtobufMagic))
        let decoded = try MacSyncCoordinator.MacSavedLists.decodeProtobuf(persisted)
        #expect(decoded.catalogueRevision == 9)
        #expect(decoded.copiesRevision == 4)
    }

    @Test("checkNotStopped awaits in-flight putGrant, keeps grantPut false on failure, and retries before checking stop")
    @MainActor
    func putGrantRaceAwaitsInFlightAndRetriesFailure() async throws {
        MemoryRelay.install()
        let folder = FileManager.default.temporaryDirectory.appending(path: "akr-grant-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let macKeys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "MacBook Pro")
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
        let signedMembersBytes = try CredentialSealing.signedDocument(members.serializedData(), by: macKeys.deviceKeyID) {
            try macKeys.signWithDeviceKey($0, context: LAContext())
        }.serializedData()

        var registration = Agentkeyring_V2_PushRegistration()
        registration.domain = "agentkeyring.push.v2"
        registration.deviceKeyID = phoneKeyID
        registration.apnsToken = Data(repeating: 0xAA, count: 32)
        registration.apnsTopic = "com.joshpalmer.AgentKeyring.Phone"
        registration.apnsProduction = true
        registration.noticePublicKey = try phoneKeys.noticePublicKey()
        registration.registeredUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signedReg = try CredentialSealing.signedDocument(registration.serializedData(), by: phoneDevice.replyKeyID) {
            try phoneKeys.signReply($0)
        }

        let leaseStore = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases")))
        let loginID = UUID()
        let candidate = CredentialCandidate(
            id: loginID,
            title: "Example",
            username: "alex@example.com",
            origins: ["https://example.com"],
            availableFields: [.password],
            possiblyStale: nil,
            lastModifiedAt: nil,
            secretDeleted: nil
        )
        var env = MacSyncEnvironment(storage: .memory())
        env.invitationStore = .nowhere
        env.relay = RelayBoxClient(checking: MemoryRelay.url)!
        env.pushRelayURL = URL(string: "https://push.test")!
        let macDevice = MacSyncCoordinator(
            keys: macKeys,
            store: MacVaultFileStore(directory: folder.appending(path: "store")),
            leaseStore: leaseStore,
            environment: env
        ) { [] }
        defer { macDevice.stopBackgroundWork() }
        #expect(await macDevice.receiveSignedMembers(signedMembersBytes) == .taken)
        #expect(macDevice.cloudSync.receivePushRegistration(try signedReg.serializedData()) == .taken)

        var req = Agentkeyring_V2_RequestLeaseRequest()
        req.requestID = "req-grant-race-1"
        req.loginID = loginID.uuidString
        req.taskRef = "task-grant-1"
        req.reason = "Verify grant ordering"
        let lease = try leaseStore.recordLeaseRequest(req, login: candidate, rule: .ask)

        macDevice.ask(for: lease, agent: "Codex", project: "AgentKeyring")
        let (askReqID, ask) = try #require(macDevice.asks.first)
        let grantBoxID = LeaseGrantBox(answerBox: ask.request.answerBoxID, key: ask.request.answerBoxKey).id
        #expect(!grantBoxID.isEmpty)

        final class GrantInterceptState: @unchecked Sendable {
            let releaseFirstPut = DispatchSemaphore(value: 0)
            var putAttempts = 0
        }
        let state = GrantInterceptState()
        MemoryRelay.setIntercept(for: grantBoxID) { request in
            if request.httpMethod == "PUT", request.value(forHTTPHeaderField: "x-akr-ttl") == "grant" {
                state.putAttempts += 1
                if state.putAttempts == 1 {
                    state.releaseFirstPut.wait()
                    return (403, Data(), [:])
                }
            }
            return nil
        }
        defer { MemoryRelay.setIntercept(for: grantBoxID, handler: nil) }

        _ = try leaseStore.approve(lease.requestID, secret: Agentkeyring_V2_LoginSecret())
        macDevice.leasesChanged()

        // Wait until the initial publishLeaseGrantBox HTTP PUT is in flight.
        while macDevice.askTasks[askReqID]?.grant == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(macDevice.asks[askReqID]?.grantPut == false)

        // Start checkNotStopped while grantPutting is in flight; it must wait and retry after PUT #1 fails.
        let checkTask = Task { try await macDevice.checkNotStopped(lease: lease.requestID) }
        try await Task.sleep(for: .milliseconds(25))
        state.releaseFirstPut.signal()

        try await checkTask.value
        #expect(state.putAttempts == 2)
        #expect(macDevice.asks[askReqID]?.grantPut == true)
        #expect(leaseStore.grantsPut.contains(lease.requestID))
    }
}
