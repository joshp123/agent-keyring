// Written by AI on 2026.11.18 by model claude opus 5.5.
// The path a login takes from a device to the machine that asked, with
// software keys standing in for the chip. The files written here are opened by
// the Go test in internal/keyring, as the command opens them on a machine; set
// AKR_WRITE_VECTORS=1 to write them again.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import Testing

struct SealingTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "testdata/keyring")
    static let decided = Date(timeIntervalSince1970: 1_795_000_000)

    struct Keys {
        let signing, reply, machineTLSKey: P256.Signing.PrivateKey
        let opening, notice, machine: P256.KeyAgreement.PrivateKey
        init() throws {
            let hex = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "keys.json"))) as! [String: String]
            func raw(_ name: String) -> Data {
                let text = hex[name]!
                return Data(stride(from: 0, to: text.count, by: 2).map {
                    UInt8(text[text.index(text.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
                })
            }
            signing = try .init(rawRepresentation: raw("device_signing"))
            reply = try .init(rawRepresentation: raw("device_reply"))
            opening = try .init(rawRepresentation: raw("device_opening"))
            notice = try .init(rawRepresentation: raw("device_notice"))
            machine = try .init(rawRepresentation: raw("machine_receiving"))
            machineTLSKey = try .init(rawRepresentation: raw("machine_tls"))
        }
        var deviceID: String { Sealing.keyID(signing.publicKey.x963Representation) }
        var replyID: String { Sealing.keyID(reply.publicKey.x963Representation) }
        var signer: Sealing.Signer { Sealing.Signer(keyID: replyID) { [reply] in try reply.signature(for: $0).derRepresentation } }
        var machineTLS: Data { machineTLSKey.publicKey.derRepresentation }
        var machineID: String { Sealing.keyID(machineTLS) }

        func members() throws -> Members {
            var device = Agentkeyring_V2_Device()
            device.keyID = deviceID
            device.kind = .iphone
            device.label = "iPhone"
            device.signingPublicKey = signing.publicKey.x963Representation
            device.openingPublicKey = opening.publicKey.x963Representation
            device.replyKeyID = replyID
            device.replyPublicKey = reply.publicKey.x963Representation
            var machine = Agentkeyring_V2_Machine()
            machine.machineID = machineID
            machine.label = "Linux server"
            machine.tlsPublicKey = machineTLS
            machine.receivingPublicKey = self.machine.publicKey.x963Representation
            machine.automaticAllowed = true
            var members = Members()
            members.domain = "agentkeyring.members.v2"
            members.revision = 1
            members.devices = [device]
            members.machines = [machine]
            return members
        }
    }

    static func request(machineID: String) throws -> Data {
        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"
        request.requestID = "request-1"
        request.loginID = "login-example"
        request.machineID = machineID
        request.reason = "You asked me to download October's invoice."
        request.agent = "Codex"
        request.askedUnixSeconds = Int64(decided.timeIntervalSince1970) - 20
        request.answerByUnixSeconds = Int64(decided.timeIntervalSince1970) + 580
        return try request.serializedData()
    }

    static let version: UInt64 = 1_795_000_000_000_000_000

    static var secret: LoginSecret {
        var secret = LoginSecret()
        secret.loginID = "login-example"
        secret.username = "example@example.com"
        secret.password = "example-password"
        secret.totpSeed = Data("12345678901234567890".utf8)
        return secret
    }

    @Test("A device opens its sealed login, seals it again for the asking machine, and the machine opens it")
    func approveForMachine() throws {
        let keys = try Keys()
        let members = try keys.members()
        let requestBytes = try Self.request(machineID: keys.machineID)
        var listed = Agentkeyring_V2_Login()
        listed.loginID = "login-example"
        listed.version = Self.version
        let sealed = try Sealing.seal(Self.secret, version: Self.version, to: keys.opening.publicKey, openerID: keys.deviceID, signer: keys.signer)
        try Sealing.checkSealed(sealed, members: members, listed: listed)
        let opened = try Sealing.open(sealed, with: keys.opening)
        // A copy the relay made itself, relabelled for another login, or kept from before the last import, is refused before it is opened.
        let stranger = P256.Signing.PrivateKey()
        let made = try Sealing.seal(Self.secret, version: Self.version, to: keys.opening.publicKey, openerID: keys.deviceID,
            signer: Sealing.Signer(keyID: keys.replyID) { try stranger.signature(for: $0).derRepresentation })
        #expect(throws: Sealing.Failure.badSignature) { try Sealing.checkSealed(made, members: members, listed: listed) }
        var relabelled = sealed
        relabelled.loginID = "another-login"
        #expect(throws: Sealing.Failure.badSignature) { try Sealing.checkSealed(relabelled, members: members, listed: nil) }
        let older = try Sealing.seal(Self.secret, version: Self.version - 1, to: keys.opening.publicKey, openerID: keys.deviceID, signer: keys.signer)
        #expect(throws: Sealing.Failure.wrongLogin) { try Sealing.checkSealed(older, members: members, listed: listed) }
        var restamped = older
        restamped.version = Self.version
        #expect(throws: Sealing.Failure.badSignature) { try Sealing.checkSealed(restamped, members: members, listed: listed) }
        let upload = try Sealing.approve(request: requestBytes, secret: opened, sites: ["https://example.com"],
            receivingKey: keys.machine.publicKey, signerKeyID: keys.deviceID, now: Self.decided) {
            try keys.signing.signature(for: $0).derRepresentation
        }
        var approval = Agentkeyring_V2_Approval()
        approval.request = requestBytes
        approval.answer = upload.answer
        approval.delivery = upload.delivery
        let contents = try Sealing.openDelivery(approval, members: members, with: keys.machine, now: Self.decided)
        #expect(contents.password == "example-password")
        #expect(contents.oneTimeCodes.count == 61)  // 30 minutes from mid-period touch 61 periods.
        #expect(contents.oneTimeCodes.first?.code == "527227")  // RFC 6238 test seed at 1795000000, as Python's hmac gives.

        // An approval signed with the reply key is refused; a denial with words is not.
        let byReplyKey = try Sealing.approve(request: requestBytes, secret: opened, sites: [], receivingKey: keys.machine.publicKey,
            signerKeyID: keys.replyID, now: Self.decided) { try keys.reply.signature(for: $0).derRepresentation }
        var forged = approval
        forged.answer = byReplyKey.answer
        forged.delivery = byReplyKey.delivery
        #expect(throws: Sealing.Failure.notAllowedForSigner) { try Sealing.openDelivery(forged, members: members, with: keys.machine, now: Self.decided) }
        let denial = try Sealing.deny(request: requestBytes, reply: "The invoice is in my email.", signerKeyID: keys.replyID,
            now: Self.decided) { try keys.reply.signature(for: $0).derRepresentation }
        var denied = Agentkeyring_V2_Approval()
        denied.request = requestBytes
        denied.answer = denial.answer
        #expect(try Sealing.verifiedAnswer(denied, members: members).reply == "The invoice is in my email.")

        guard ProcessInfo.processInfo.environment["AKR_WRITE_VECTORS"] == "1" else { return }
        let signedMembers = try Sealing.signed(members.serializedData(), by: keys.deviceID) {
            try keys.signing.signature(for: $0).derRepresentation
        }
        let automatic = try Sealing.seal(Self.secret, version: Self.version, to: keys.machine.publicKey, openerID: keys.machineID, signer: keys.signer)
        try signedMembers.serializedData().write(to: Self.folder.appending(path: "swift-members.pb"))
        try approval.serializedData().write(to: Self.folder.appending(path: "swift-approval.pb"))
        try denied.serializedData().write(to: Self.folder.appending(path: "swift-denial.pb"))
        try automatic.serializedData().write(to: Self.folder.appending(path: "swift-automatic.pb"))
    }

    @Test("A push the relay sealed in Go opens with the device's notice key")
    func noticeFromRelay() throws {
        let keys = try Keys()
        let notice = try Agentkeyring_V2_Notice(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-notice.pb")))
        let work = try Sealing.openNotice(notice, deviceKeyID: keys.deviceID, with: keys.notice)
        let request = try Sealing.parseRequest(work.request)
        #expect(request.reason == "You asked me to download October's invoice.")
        #expect(try Sealing.open(work.sealedLogin, with: keys.opening).password == "example-password")
    }

    @Test("A request the asking machine signed in Go is shown; one the relay changed or made is refused")
    func requestFromGo() throws {
        let keys = try Keys()
        let members = try keys.members()
        let work = try Agentkeyring_V2_Work(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-request.pb")))
        #expect(try Sealing.checkRequest(work, members: members, ownKeyID: keys.deviceID)?.machineID == keys.machineID)
        var redirected = work
        var request = try Sealing.parseRequest(work.request)
        request.loginID = "another-login"
        redirected.request = try request.serializedData()
        #expect(throws: Sealing.Failure.badSignature) { try Sealing.checkRequest(redirected, members: members, ownKeyID: keys.deviceID) }
        var unsigned = work
        unsigned.requestSignature = Data()
        #expect(throws: Sealing.Failure.badSignature) { try Sealing.checkRequest(unsigned, members: members, ownKeyID: keys.deviceID) }
    }

    @Test("A device's own practice request comes unsigned; one for another device, or naming a computer, does not")
    func practiceRequest() throws {
        let keys = try Keys()
        let members = try keys.members()
        var practice = KeyringRequest()
        practice.domain = "agentkeyring.request.v2"
        practice.requestID = "practice-1"
        practice.forDeviceKeyID = keys.deviceID
        var work = Agentkeyring_V2_Work()
        work.request = try practice.serializedData()
        #expect(try Sealing.checkRequest(work, members: members, ownKeyID: keys.deviceID) == nil)
        #expect(throws: Sealing.Failure.unknownSigner) { try Sealing.checkRequest(work, members: members, ownKeyID: "another-device") }
        practice.machineID = keys.machineID
        work.request = try practice.serializedData()
        #expect(throws: Sealing.Failure.badSignature) { try Sealing.checkRequest(work, members: members, ownKeyID: keys.deviceID) }
    }

    @Test("A join proof made in Go checks in Swift")
    func joinProofFromGo() throws {
        let joining = try Agentkeyring_V2_JoinRequest(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-join.pb")))
        #expect(Sealing.joinProof(secret: Data(repeating: 1, count: 32), joining: joining) == joining.proof)
        #expect(Sealing.joinProof(secret: Data(repeating: 2, count: 32), joining: joining) != joining.proof)
    }

    @Test("The Mac's proof for an empty relay is the one the relay in Go checks")
    func setupProofMatchesGo() {
        // The same vector is checked against Go in internal/keyring (TestSetupProofMatchesTheMac).
        let proof = Sealing.setupProof(secret: Data(repeating: 1, count: 32), relaySPKI: Data("spki".utf8), firstDeviceKeyID: "mac")
        #expect(proof.map { String(format: "%02x", $0) }.joined() == "8572ae376638705097f47924d256bf18bf09e85ab4eaeaa4fe57ad27392da3bb")
    }

    @Test("A refusal made in Go checks in Swift")
    func refusalFromGo() throws {
        let refusal = try Agentkeyring_V2_JoinRefusal(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-refusal.pb")))
        let secret = Data(repeating: 1, count: 32)
        #expect(Sealing.refusalKey(secret: secret, machineID: refusal.joinerID) == refusal.key)
        #expect(Sealing.refusalReplyProof(secret: secret, machineID: refusal.joinerID, reply: refusal.reply) == refusal.replyProof)
        #expect(Sealing.refusalReplyProof(secret: secret, machineID: refusal.joinerID, reply: "Something else.") != refusal.replyProof)
    }
}
