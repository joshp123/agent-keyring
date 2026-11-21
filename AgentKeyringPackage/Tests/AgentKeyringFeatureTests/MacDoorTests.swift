// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// The Mac's door, run in this process on 127.0.0.1 against a stand-in iPhone,
// a stand-in Apple Watch and a stand-in for Apple's push service: the path a
// person takes from adding his iPhone to answering an agent's request. Every
// key is made up here; nothing reaches Apple, a real device or the keychain.

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import AgentKeyringFeature

/// One stand-in device: its keys, as the iPhone and Watch apps hold them.
private struct StandInDevice {
    let tls: RelayTLSIdentity?
    let signing = P256.Signing.PrivateKey()
    let opening = P256.KeyAgreement.PrivateKey()
    let reply = P256.Signing.PrivateKey()
    let notice = P256.KeyAgreement.PrivateKey()
    let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let device: Agentkeyring_V2_Device

    init(kind: Agentkeyring_V2_DeviceKind, label: String) throws {
        tls = kind == .watch ? nil : try RelayTLSIdentity.ephemeral()
        var device = Agentkeyring_V2_Device()
        device.kind = kind
        device.label = label
        device.signingPublicKey = signing.publicKey.x963Representation
        device.keyID = Sealing.keyID(device.signingPublicKey)
        device.openingPublicKey = opening.publicKey.x963Representation
        device.tlsPublicKey = tls?.publicKeySPKI ?? Data()
        device.replyPublicKey = reply.publicKey.x963Representation
        device.replyKeyID = Sealing.keyID(device.replyPublicKey)
        self.device = device
    }

    var keyID: String { device.keyID }
    func sign(_ payload: Data) throws -> Agentkeyring_V2_Signed {
        try Sealing.signed(payload, by: keyID) { try signing.signature(for: $0).derRepresentation }
    }
    func signReply(_ payload: Data) throws -> Agentkeyring_V2_Signed {
        try Sealing.signed(payload, by: device.replyKeyID) { try reply.signature(for: $0).derRepresentation }
    }
    var replySigner: Sealing.Signer { Sealing.Signer(keyID: device.replyKeyID) { try reply.signature(for: $0).derRepresentation } }
}

/// HTTPS to a door on 127.0.0.1, pinned to its key, with a client certificate when given one.
private final class Client: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pin: Data
    let identity: RelayTLSIdentity?
    init(pin: Data, identity: RelayTLSIdentity?) { self.pin = pin; self.identity = identity }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(identity: identity.identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                (try? RelayTLSIdentity.spki(certificate: leaf)) == pin else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        default: return (.performDefaultHandling, nil)
        }
    }

    func call(_ method: String, port: UInt16, _ path: String, _ body: Data? = nil) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// What the stand-in for Apple's service was sent.
private final class ApplePushes: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [DoorRequest] = []
    func add(_ request: DoorRequest) { lock.withLock { all.append(request) } }
    var received: [DoorRequest] { lock.withLock { all } }
}

@MainActor
private func eventually(_ what: String, within seconds: Double = 10, _ check: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !check() {
        guard Date() < end else { Issue.record("Timed out waiting for \(what)"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
@Suite(.serialized)
struct MacDoorTests {
    @Test func anIPhoneJoinsTheMacGetsItsCopiesAndAnswersAPushedRequest() async throws {
        UserDefaults.standard.register(defaults: ["StandInKey": true]) // Touch ID answers at once; volatile, never saved.
        let folder = FileManager.default.temporaryDirectory.appending(path: "mac-door-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        // The stand-in for Apple's push service, with the team's made-up key.
        let pushes = ApplePushes()
        let appleIdentity = try RelayTLSIdentity.ephemeral()
        let apple = try DoorServer(identity: appleIdentity, host: "127.0.0.1", port: 0) { request in
            pushes.add(request)
            return .ok()
        }
        let applePort = try await apple.start()
        defer { apple.stop() }
        let teamKey = P256.Signing.PrivateKey()

        // The Mac, with one password.
        let keys = MacKeys(testing: try RelayTLSIdentity.ephemeral(), label: "Test Mac")
        let store = LoginStore(directory: folder.appending(path: "logins"))
        let leases = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases")))
        let loginID = UUID()
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = loginID.uuidString
        secret.username = "you@example.com"
        secret.password = "correct horse"
        secret.title = "example.com"
        secret.sites = ["https://example.com"]
        try await store.replaceSealed([try Sealing.seal(secret, version: 7, to: keys.openingPublicKey, openerID: keys.deviceKeyID, signer: keys.signer)])
        var login = Agentkeyring_V2_Login()
        login.loginID = loginID.uuidString
        login.title = "example.com"
        login.sites = ["https://example.com"]
        login.account = "you@example.com"
        login.rule = .ask
        login.version = 7
        final class Left: @unchecked Sendable { var invite: Agentkeyring_V2_JoinInvite? }
        let left = Left()
        var environment = MacDevice.Environment(storage: .memory())
        environment.address = { "127.0.0.1" }
        environment.answerPort = 0
        environment.membersPort = 0
        environment.gateway = ApplePush.Gateway(production: URL(string: "https://127.0.0.1:\(applePort)/production")!,
            sandbox: URL(string: "https://127.0.0.1:\(applePort)/sandbox")!, pin: appleIdentity.publicKeySPKI)
        environment.invitationItem = InvitationItem(read: { left.invite }, write: { left.invite = $0 })
        environment.joinWait = .seconds(5)
        environment.complaints = folder.appending(path: "complaints.pb")
        let mac = MacDevice(keys: keys, store: store, leaseStore: leases, environment: environment) { [login] in [login] }
        try mac.setPushCredential(keyID: "TESTKEY123", teamID: "TESTTEAM12", privateKey: teamKey.derRepresentation)
        mac.followLeases()
        await mac.reconcileDoor()
        guard case let .open(_, answers, port) = mac.door else { Issue.record("The door did not open: \(mac.door)"); return }
        let macKey = keys.tls.publicKeySPKI

        // The iPhone joins with the invitation the Mac left in iCloud Keychain.
        let invite = try #require(left.invite)
        #expect(invite.doorHost == "127.0.0.1" && invite.doorPort == UInt32(port) && invite.doorTlsPublicKey == macKey && !invite.secret.isEmpty)
        let phone = try StandInDevice(kind: .iphone, label: "Test iPhone")
        let phoneDoor = Client(pin: macKey, identity: phone.tls)
        let bare = Client(pin: macKey, identity: nil) // As the Watch and a locked iPhone's extension call.
        var joining = Agentkeyring_V2_JoinRequest()
        joining.device = phone.device
        joining.proof = Sealing.joinProof(secret: invite.secret, joining: joining)
        let joinBody = try joining.serializedData()
        let joined = Task { try await phoneDoor.call("POST", port: port, "/v2/join", joinBody) }
        try await eventually("the join to show") { !mac.joins.isEmpty }
        try await mac.approveJoin(phone.keyID, thisMacAutomatic: false, context: LAContext(), onAuthenticated: {})
        let joinReply = try await joined.value
        #expect(joinReply.status == 200)
        let status = try Agentkeyring_V2_JoinStatus(serializedBytes: joinReply.body)
        #expect(status.state == .approved)
        let members1 = try Sealing.verifiedMembers(status.members, current: nil)
        #expect(members1.devices.map(\.keyID).contains(phone.keyID))
        #expect(left.invite?.secret != invite.secret) // Each secret admits one joiner.
        try await eventually("the iPhone's copies") { mac.filling == nil }

        // Its bundle: the lists, every members revision, and its own copy, which opens to the password.
        let bundle1 = try Agentkeyring_V2_Bundle(serializedBytes: try await phoneDoor.call("GET", port: port, "/v2/bundle?members=0").body)
        #expect(bundle1.membersSince.count == 1)
        let catalogue = try Sealing.verifiedCatalogue(bundle1.catalogue, members: members1, current: nil)
        let phoneCopy = try #require(bundle1.copies.first { $0.openerID == phone.keyID })
        try Sealing.checkSealed(phoneCopy, members: members1, listed: catalogue.logins.first)
        #expect(try Sealing.open(phoneCopy, with: phone.opening).password == "correct horse")
        // Only a member's connection gets one: the members' door refuses a connection with no certificate.
        await #expect(throws: (any Error).self) { try await bare.call("GET", port: port, "/v2/bundle") }
        #expect(try await bare.call("GET", port: answers, "/v2/bundle").status == 404)

        // The iPhone adds its Watch, gives it its copies, and registers both push addresses.
        let watch = try StandInDevice(kind: .watch, label: "Test Watch")
        var members2 = members1
        members2.revision = 2
        members2.devices.append(watch.device)
        #expect(try await phoneDoor.call("POST", port: port, "/v2/members", try phone.sign(members2.serializedData()).serializedData()).status == 200)
        var forWatch = Agentkeyring_V2_SealedLogins()
        forWatch.logins = [try Sealing.seal(try Sealing.open(phoneCopy, with: phone.opening), version: 7,
            to: watch.opening.publicKey, openerID: watch.keyID, signer: phone.replySigner)]
        #expect(try await phoneDoor.call("POST", port: port, "/v2/copies", try forWatch.serializedData()).status == 200)
        for (device, label) in [(phone, "iPhone"), (watch, "Watch")] {
            var registration = Agentkeyring_V2_PushRegistration()
            registration.domain = "agentkeyring.push.v2"
            registration.deviceKeyID = device.keyID
            registration.apnsToken = device.token
            registration.apnsTopic = "com.example.test." + label
            registration.noticePublicKey = device.notice.publicKey.x963Representation
            registration.registeredUnixSeconds = Int64(Date().timeIntervalSince1970)
            let reply = try await phoneDoor.call("POST", port: port, "/v2/push-registration", try phone.signReply(registration.serializedData()).serializedData())
            #expect(reply.status == 200, "\(String(decoding: reply.body, as: UTF8.self))")
        }
        let bundle2 = try Agentkeyring_V2_Bundle(serializedBytes: try await phoneDoor.call("GET", port: port, "/v2/bundle?members=1").body)
        #expect(bundle2.membersSince.count == 1 && bundle2.pushRegistrations.count == 2)

        // An agent on the Mac asks: the Mac pushes to both through Apple, naming its own door.
        let lease = try leases.request(Self.leaseRequest(loginID), login: Self.candidate(loginID), policy: .ask)
        mac.ask(for: lease, agent: "Test Agent", project: "example")
        try await eventually("two visible pushes") { pushes.received.filter { $0.headers["apns-push-type"] == "alert" }.count == 2 }
        let visible = pushes.received.filter { $0.headers["apns-push-type"] == "alert" }
        let toPhone = try #require(visible.first { $0.path.hasSuffix(phone.token.map { String(format: "%02x", $0) }.joined()) })
        #expect(toPhone.path.hasPrefix("/sandbox/3/device/") && toPhone.headers["apns-priority"] == "10")
        try Self.checkToken(toPhone.headers["authorization"], key: teamKey.publicKey)
        let work = try Self.work(toPhone, device: phone)
        let request = try Sealing.parseRequest(work.request)
        #expect(request.answerAddress == "127.0.0.1:\(answers)" && request.answerTlsPublicKey == macKey && !work.hasSealedLogin)
        let listedMembers = try Agentkeyring_V2_Members(serializedBytes: bundle2.members.payload)
        let macMachine = try #require(listedMembers.machines.first { $0.machineID == keys.machineID })
        let signature = try P256.Signing.ECDSASignature(derRepresentation: work.requestSignature)
        #expect(try P256.Signing.PublicKey(derRepresentation: macMachine.tlsPublicKey).isValidSignature(signature, for: work.request))
        let watchWork = try Self.work(try #require(visible.first { $0 != toPhone }), device: watch)
        #expect(watchWork.sealedLogin == forWatch.logins[0]) // The Watch's push carries its copy.

        // The locked iPhone's extension notes the arrival, unsigned, by its push address.
        var arrival = Agentkeyring_V2_Arrival()
        arrival.domain = "agentkeyring.arrival.v2"
        arrival.requestID = request.requestID
        arrival.deviceKeyID = phone.keyID
        arrival.pushTokenSha256 = Sealing.sha256(phone.token)
        var unsigned = Agentkeyring_V2_Signed()
        unsigned.payload = try arrival.serializedData()
        #expect(try await bare.call("POST", port: answers, "/v2/arrived", try unsigned.serializedData()).status == 200)
        #expect(mac.lease(request.requestID)?.arrivedOn == "Test iPhone")

        // He approves on the iPhone: the first answer wins, the lease is active, and the devices hear the outcome.
        let approval = try Sealing.approve(request: work.request, secret: try Sealing.open(phoneCopy, with: phone.opening), sites: login.sites,
            receivingKey: keys.receiving.publicKey, signerKeyID: phone.keyID) { try phone.signing.signature(for: $0).derRepresentation }
        let answered = try await bare.call("POST", port: answers, "/v2/answer", try approval.serializedData())
        #expect(answered.status == 200)
        let approved = try Agentkeyring_V2_Lease(serializedBytes: answered.body)
        #expect(approved.state == .approved && approved.answeredBy == "Test iPhone")
        let active = try leases.get(lease.leaseID)
        #expect(active.state == .active && active.approvedBy == .iphone)
        try await eventually("the outcome pushes") {
            pushes.received.filter { $0.headers["apns-push-type"] == "background" && $0.headers["apns-collapse-id"] == request.requestID }.count == 2
        }
        let late = try Sealing.deny(request: work.request, reply: "no", signerKeyID: watch.device.replyKeyID) { try watch.reply.signature(for: $0).derRepresentation }
        let lateReply = try await bare.call("POST", port: answers, "/v2/answer", try late.serializedData())
        let lateLease = try Agentkeyring_V2_Lease(serializedBytes: lateReply.body)
        #expect(lateReply.status == 200 && lateLease.state == .approved)

        // Stop on the Watch ends it at once.
        var end = Agentkeyring_V2_EndRequest()
        end.domain = "agentkeyring.end.v2"
        end.requestID = request.requestID
        end.deviceKeyID = watch.keyID
        end.endedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let stopped = try await bare.call("POST", port: answers, "/v2/end", try watch.signReply(end.serializedData()).serializedData())
        #expect(stopped.status == 200)
        let ended = try Agentkeyring_V2_Lease(serializedBytes: stopped.body)
        #expect(ended.state == .ended && ended.endedBy == "Test Watch")
        #expect(try leases.get(lease.leaseID).state == .revoked)

        // A second request, denied on the Watch with words: recorded as the Watch's, and the agent is held off.
        let second = try leases.request(Self.leaseRequest(loginID), login: Self.candidate(loginID), policy: .ask)
        mac.ask(for: second, agent: "Test Agent", project: "example")
        try await eventually("the second request's pushes") { pushes.received.filter { $0.headers["apns-push-type"] == "alert" }.count == 4 }
        let secondWork = try Self.work(try #require(pushes.received.last { $0.headers["apns-push-type"] == "alert" && $0.path.contains(watch.token.map { String(format: "%02x", $0) }.joined()) }), device: watch)
        let denial = try Sealing.deny(request: secondWork.request, reply: "Not now", signerKeyID: watch.device.replyKeyID) {
            try watch.reply.signature(for: $0).derRepresentation
        }
        #expect(try await bare.call("POST", port: answers, "/v2/answer", try denial.serializedData()).status == 200)
        let denied = try leases.get(second.leaseID)
        #expect(denied.state == .denied && denied.approvedBy == .watch && denied.reply == "Not now" && denied.retryNotBeforeUnixSeconds > 0)

        // The iPhone asks for a practice request on its Watch: the Mac makes it, pushes it, and takes the Watch's approval.
        var practice = Agentkeyring_V2_PracticeAsk()
        practice.domain = "agentkeyring.practice.v2"
        practice.forDeviceKeyID = watch.keyID
        practice.requestID = String(repeating: "ab", count: 16)
        let asked = try await phoneDoor.call("POST", port: port, "/v2/practice", try phone.signReply(practice.serializedData()).serializedData())
        #expect(asked.status == 200 && String(decoding: asked.body, as: UTF8.self) == practice.requestID)
        try await eventually("the practice push") { pushes.received.contains { $0.headers["apns-collapse-id"] == practice.requestID } }
        let practiceWork = try Self.work(try #require(pushes.received.first { $0.headers["apns-collapse-id"] == practice.requestID }), device: watch)
        var practiceAnswer = Agentkeyring_V2_Answer()
        practiceAnswer.domain = "agentkeyring.answer.v2"
        practiceAnswer.requestSha256 = Sealing.sha256(practiceWork.request)
        practiceAnswer.choice = .approve
        practiceAnswer.decidedUnixSeconds = Int64(Date().timeIntervalSince1970)
        practiceAnswer.notAfterUnixSeconds = practiceAnswer.decidedUnixSeconds + 60
        var practiceUpload = Agentkeyring_V2_AnswerUpload()
        practiceUpload.answer = try watch.sign(practiceAnswer.serializedData())
        let practiced = try await bare.call("POST", port: answers, "/v2/answer", try practiceUpload.serializedData())
        let practiceLease = try Agentkeyring_V2_Lease(serializedBytes: practiced.body)
        #expect(practiced.status == 200 && practiceLease.state == .approved)

        // The iPhone heard the lists change, from a silent push.
        try await eventually("the silent push that the lists changed", within: 5) {
            pushes.received.contains { $0.headers["apns-collapse-id"] == "rev" && $0.headers["apns-push-type"] == "background"
                && $0.path.contains(phone.token.map { String(format: "%02x", $0) }.joined()) }
        }
        for server in mac.servers { server.stop() }
    }

    /// The iPhone engineer's half: the iPhone app's own PhoneKeyring, not a stand-in, against this Mac's real door,
    /// walking what he does first: find the Mac from its card, join and be approved, get its copies, register for
    /// pushes, answer a pushed request at the asking computer's door, ask for a practice request, add its Watch
    /// with the Watch's copies, and Stop, with the Stop left at the Mac when the asking computer's door is closed.
    @Test func theIPhoneAppJoinsTheRealMacAndAnswers() async throws {
        UserDefaults.standard.register(defaults: ["StandInKey": true])
        Tailnet.acceptsLoopbackForTests = true
        defer { Tailnet.acceptsLoopbackForTests = false }
        let folder = FileManager.default.temporaryDirectory.appending(path: "phone-door-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let pushes = ApplePushes()
        let appleIdentity = try RelayTLSIdentity.ephemeral()
        let apple = try DoorServer(identity: appleIdentity, host: "127.0.0.1", port: 0) { request in pushes.add(request); return .ok() }
        let applePort = try await apple.start()
        defer { apple.stop() }

        let keys = MacKeys(testing: try RelayTLSIdentity.ephemeral(), label: "Test Mac")
        let store = LoginStore(directory: folder.appending(path: "logins"))
        let leases = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases")))
        let loginID = UUID()
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = loginID.uuidString
        secret.username = "you@example.com"
        secret.password = "correct horse"
        secret.title = "example.com"
        secret.sites = ["https://example.com"]
        try await store.replaceSealed([try Sealing.seal(secret, version: 7, to: keys.openingPublicKey, openerID: keys.deviceKeyID, signer: keys.signer)])
        var login = Agentkeyring_V2_Login()
        login.loginID = loginID.uuidString
        login.title = "example.com"
        login.sites = ["https://example.com"]
        login.account = "you@example.com"
        login.rule = .ask
        login.version = 7
        final class Left: @unchecked Sendable { var invite: Agentkeyring_V2_JoinInvite? }
        let left = Left()
        var environment = MacDevice.Environment(storage: .memory())
        environment.address = { "127.0.0.1" }
        environment.answerPort = 0
        environment.membersPort = 0
        environment.gateway = ApplePush.Gateway(production: URL(string: "https://127.0.0.1:\(applePort)/production")!,
            sandbox: URL(string: "https://127.0.0.1:\(applePort)/sandbox")!, pin: appleIdentity.publicKeySPKI)
        environment.invitationItem = InvitationItem(read: { left.invite }, write: { left.invite = $0 })
        environment.joinWait = .seconds(5)
        environment.complaints = folder.appending(path: "complaints.pb")
        let mac = MacDevice(keys: keys, store: store, leaseStore: leases, environment: environment) { [login] in [login] }
        try mac.setPushCredential(keyID: "TESTKEY123", teamID: "TESTTEAM12", privateKey: P256.Signing.PrivateKey().derRepresentation)
        mac.followLeases()
        await mac.reconcileDoor()
        guard case .open = mac.door else { Issue.record("The door did not open: \(mac.door)"); return }
        defer { for server in mac.servers { server.stop() } }

        // The iPhone app, with software keys in place of its Secure Enclave, finds the Mac from its card.
        let phoneKeys = SoftwarePhoneKeys()
        let tls = try RelayTLSIdentity.ephemeral()
        let phone = PhoneKeyring(directory: folder.appending(path: "phone"), shared: PhoneSharedContext(accessGroup: nil),
                                 keys: phoneKeys, identity: { tls })
        let card = try #require(left.invite)
        let link = "agentkeyring://join?invite=" + (try card.serializedData()).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try await phone.join(invitation: link)
        try await eventually("the iPhone to find the Mac") { if case .foundMac = phone.snapshot.firstRun { true } else { false } }
        #expect(phone.snapshot.firstRun == .foundMac(name: "Test Mac"))

        // Connect: the join shows on the Mac, he approves, and the iPhone gets its copies.
        await phone.firstRun(.connect)
        try await eventually("the join to show on the Mac") { !mac.joins.isEmpty }
        try await mac.approveJoin(try #require(mac.joins.first).request.device.keyID, thisMacAutomatic: false, context: LAContext(), onAuthenticated: {})
        try await eventually("first run to reach notifications", within: 20) { phone.snapshot.firstRun == .notifications }
        #expect(phone.snapshot.joined && phone.snapshot.logins.map(\.site) == ["example.com"])

        // Push address, signed with the reply key.
        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await phone.registerPush(token: token, topic: "com.example.test.phone", production: false)
        let hexToken = token.map { String(format: "%02x", $0) }.joined()

        // An agent on the Mac asks; the push reaches the iPhone app, which approves at the Mac's answer door.
        let lease = try leases.request(Self.leaseRequest(loginID), login: Self.candidate(loginID), policy: .ask)
        mac.ask(for: lease, agent: "Test Agent", project: "example")
        try await eventually("the push to the iPhone") { pushes.received.contains { $0.headers["apns-push-type"] == "alert" && $0.path.hasSuffix(hexToken) } }
        let push = try #require(pushes.received.first { $0.headers["apns-push-type"] == "alert" && $0.path.hasSuffix(hexToken) })
        await phone.received(try #require(JSONSerialization.jsonObject(with: push.body) as? [AnyHashable: Any]))
        let request = try #require(phone.snapshot.requests.first { $0.state.isWaitingForYou })
        #expect(request.login.site == "example.com" && request.agent.machine == "Test Mac")
        try await phone.approve(request.id, reusingUnlock: false)
        #expect(try leases.get(lease.leaseID).state == .active)
        #expect(phone.snapshot.requests.contains { $0.id == request.id && $0.state.isInUse })

        // Stop, at the asking computer's door.
        try await phone.stop(request.id)
        #expect(try leases.get(lease.leaseID).state == .revoked)

        // A practice request for this iPhone, made and pushed by the Mac.
        _ = await phone.sendPractice(to: nil)
        try await eventually("the practice push") { pushes.received.contains { $0.path.hasSuffix(hexToken) && $0.headers["apns-collapse-id"]?.count == 32 } }

        // The Watch: Face ID first, then the Watch asks, then its copies go to the Mac.
        let watch = try StandInDevice(kind: .watch, label: "Test Watch")
        phone.watchPairing(paired: true, installed: true)
        await phone.addWatch(.open)
        await phone.addWatch(.continueWithFaceID)
        #expect({ if case .waitingForWatch = phone.snapshot.addWatch { true } else { false } }())
        var watchPush = Agentkeyring_V2_PushRegistration()
        watchPush.deviceKeyID = watch.keyID
        watchPush.apnsToken = watch.token
        watchPush.apnsTopic = "com.example.test.watch"
        watchPush.noticePublicKey = watch.notice.publicKey.x963Representation
        phone.watchOffered(device: try watch.device.serializedData(), push: try watchPush.serializedData())
        try await eventually("the Watch to be added", within: 20) { phone.snapshot.addWatch == .added }
        let watchHex = watch.token.map { String(format: "%02x", $0) }.joined()
        let second = try leases.request(Self.leaseRequest(loginID), login: Self.candidate(loginID), policy: .ask)
        mac.ask(for: second, agent: "Test Agent", project: "example")
        try await eventually("a push to the Watch carrying its copy") { pushes.received.contains { $0.headers["apns-push-type"] == "alert" && $0.path.hasSuffix(watchHex) } }
        let watchWork = try Self.work(try #require(pushes.received.last { $0.headers["apns-push-type"] == "alert" && $0.path.hasSuffix(watchHex) }), device: watch)
        #expect(try Sealing.open(watchWork.sealedLogin, with: watch.opening).password == "correct horse")

        // Stop when no process holds the asking computer's door: it is left at the Mac.
        let pushToPhone = try #require(pushes.received.last { $0.headers["apns-push-type"] == "alert" && $0.path.hasSuffix(hexToken) })
        await phone.received(try #require(JSONSerialization.jsonObject(with: pushToPhone.body) as? [AnyHashable: Any]))
        let secondRequest = try #require(phone.snapshot.requests.first { $0.state.isWaitingForYou })
        try await phone.approve(secondRequest.id, reusingUnlock: false)
        mac.servers.first?.stop() // The answer door: [answers, members].
        AnswerDoor.retryFor = 1
        defer { AnswerDoor.retryFor = 30 }
        await #expect(throws: PhoneStopWaitsWithMac.self) { try await phone.stop(secondRequest.id) }
    }

    static func leaseRequest(_ loginID: UUID) -> Agentkeyring_V1_RequestLeaseRequest {
        var request = Agentkeyring_V1_RequestLeaseRequest()
        request.loginID = loginID.uuidString
        request.requestID = UUID().uuidString
        request.taskRef = "task-\(UUID().uuidString.prefix(6))"
        request.reason = "Sign in to example.com to download the invoice."
        return request
    }

    static func candidate(_ loginID: UUID) -> CredentialCandidate {
        CredentialCandidate(id: loginID, title: "example.com", username: "you@example.com", origins: ["https://example.com"],
            availableFields: [.username, .password])
    }

    /// The Work in a push, opened with the device's notice key as its notification extension does.
    private static func work(_ push: DoorRequest, device: StandInDevice) throws -> Agentkeyring_V2_Work {
        let payload = try JSONSerialization.jsonObject(with: push.body) as? [String: Any]
        let akr = payload?["akr"] as? String ?? ""
        let notice = try Agentkeyring_V2_Notice(serializedBytes: Data(base64Encoded: akr) ?? Data())
        return try Sealing.openNotice(notice, deviceKeyID: device.keyID, with: device.notice)
    }

    /// Apple's provider token: ES256 over header and claims, a raw r and s.
    static func checkToken(_ header: String?, key: P256.Signing.PublicKey) throws {
        let token = try #require(header?.split(separator: " ").last).split(separator: ".").map(String.init)
        #expect(token.count == 3)
        func bytes(_ part: String) -> Data {
            var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            return Data(base64Encoded: text) ?? Data()
        }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes(token[2]))
        #expect(key.isValidSignature(signature, for: Data((token[0] + "." + token[1]).utf8)))
        #expect(String(decoding: bytes(token[0]), as: UTF8.self).contains("\"kid\":\"TESTKEY123\""))
    }
}

/// The iPhone's four keys in software, in place of its Secure Enclave; Face ID always says yes.
@MainActor
private final class SoftwarePhoneKeys: PhoneDeviceKeys {
    let signing = P256.Signing.PrivateKey()
    let opening = P256.KeyAgreement.PrivateKey()
    let reply = P256.Signing.PrivateKey()
    let notice = P256.KeyAgreement.PrivateKey()
    func signingPublicKey() throws -> Data { signing.publicKey.x963Representation }
    func openingPublicKey() throws -> Data { opening.publicKey.x963Representation }
    func replyPublicKey() throws -> Data { reply.publicKey.x963Representation }
    func noticePublicKey() throws -> Data { notice.publicKey.x963Representation }
    func authorize(_ context: LAContext, reason: String) async throws {}
    func sign(_ bytes: Data, context: LAContext) throws -> Data { try signing.signature(for: bytes).derRepresentation }
    func open(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { try Sealing.open(sealed, with: opening) }
    func signReply(_ bytes: Data) throws -> Data { try reply.signature(for: bytes).derRepresentation }
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_Work {
        try Sealing.openNotice(notice, deviceKeyID: deviceKeyID, with: self.notice)
    }
}

extension DoorRequest: Equatable {
    public static func == (lhs: DoorRequest, rhs: DoorRequest) -> Bool { lhs.path == rhs.path && lhs.body == rhs.body }
}
