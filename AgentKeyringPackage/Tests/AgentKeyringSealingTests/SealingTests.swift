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
        var deviceID: String { CredentialSealing.keyID(signing.publicKey.x963Representation) }
        var replyID: String { CredentialSealing.keyID(reply.publicKey.x963Representation) }
        var signer: PayloadReplySigner { PayloadReplySigner(keyID: replyID) { [reply] in try reply.signature(for: $0).derRepresentation } }
        var machineTLS: Data { machineTLSKey.publicKey.derRepresentation }
        var machineID: String { CredentialSealing.keyID(machineTLS) }

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
        let sealed = try CredentialSealing.sealLogin(Self.secret, version: Self.version, to: keys.opening.publicKey, openerID: keys.deviceID, signer: keys.signer)
        try CredentialSealing.verifySealedLogin(sealed, members: members, listed: listed)
        let opened = try CredentialSealing.openSealedLogin(sealed, with: keys.opening)
        // A copy the relay made itself, relabelled for another login, or kept from before the last import, is refused before it is opened.
        let stranger = P256.Signing.PrivateKey()
        let made = try CredentialSealing.sealLogin(Self.secret, version: Self.version, to: keys.opening.publicKey, openerID: keys.deviceID,
            signer: PayloadReplySigner(keyID: keys.replyID) { try stranger.signature(for: $0).derRepresentation })
        #expect(throws: CredentialSealingError.badSignature) { try CredentialSealing.verifySealedLogin(made, members: members, listed: listed) }
        var relabelled = sealed
        relabelled.loginID = "another-login"
        #expect(throws: CredentialSealingError.badSignature) { try CredentialSealing.verifySealedLogin(relabelled, members: members, listed: nil) }
        let older = try CredentialSealing.sealLogin(Self.secret, version: Self.version - 1, to: keys.opening.publicKey, openerID: keys.deviceID, signer: keys.signer)
        #expect(throws: CredentialSealingError.wrongLogin) { try CredentialSealing.verifySealedLogin(older, members: members, listed: listed) }
        var restamped = older
        restamped.version = Self.version
        #expect(throws: CredentialSealingError.badSignature) { try CredentialSealing.verifySealedLogin(restamped, members: members, listed: listed) }
        let upload = try CredentialSealing.buildSignedApproval(request: requestBytes, secret: opened, sites: ["https://example.com"],
            receivingKey: keys.machine.publicKey, signerKeyID: keys.deviceID, now: Self.decided) {
            try keys.signing.signature(for: $0).derRepresentation
        }
        var approval = Agentkeyring_V2_Approval()
        approval.request = requestBytes
        approval.answer = upload.answer
        approval.delivery = upload.delivery
        let contents = try CredentialSealing.openDelivery(approval, members: members, with: keys.machine, now: Self.decided)
        #expect(contents.password == "example-password")
        #expect(contents.oneTimeCodes.count == 61)  // 30 minutes from mid-period touch 61 periods.
        #expect(contents.oneTimeCodes.first?.code == "527227")  // RFC 6238 test seed at 1795000000, as Python's hmac gives.

        // An approval signed with the reply key is refused; a denial with words is not.
        let byReplyKey = try CredentialSealing.buildSignedApproval(request: requestBytes, secret: opened, sites: [], receivingKey: keys.machine.publicKey,
            signerKeyID: keys.replyID, now: Self.decided) { try keys.reply.signature(for: $0).derRepresentation }
        var forged = approval
        forged.answer = byReplyKey.answer
        forged.delivery = byReplyKey.delivery
        #expect(throws: CredentialSealingError.notAllowedForSigner) { try CredentialSealing.openDelivery(forged, members: members, with: keys.machine, now: Self.decided) }
        let denial = try CredentialSealing.buildSignedDenial(request: requestBytes, reply: "The invoice is in my email.", signerKeyID: keys.replyID,
            now: Self.decided) { try keys.reply.signature(for: $0).derRepresentation }
        var denied = Agentkeyring_V2_Approval()
        denied.request = requestBytes
        denied.answer = denial.answer
        #expect(try CredentialSealing.verifyRequestAnswer(denied, members: members).reply == "The invoice is in my email.")

        guard ProcessInfo.processInfo.environment["AKR_WRITE_VECTORS"] == "1" else { return }
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: keys.deviceID) {
            try keys.signing.signature(for: $0).derRepresentation
        }
        let automatic = try CredentialSealing.sealLogin(Self.secret, version: Self.version, to: keys.machine.publicKey, openerID: keys.machineID, signer: keys.signer)
        try signedMembers.serializedData().write(to: Self.folder.appending(path: "swift-members.pb"))
        try approval.serializedData().write(to: Self.folder.appending(path: "swift-approval.pb"))
        try denied.serializedData().write(to: Self.folder.appending(path: "swift-denial.pb"))
        try automatic.serializedData().write(to: Self.folder.appending(path: "swift-automatic.pb"))
    }

    @Test("A push the relay sealed in Go opens with the device's notice key")
    func noticeFromRelay() throws {
        let keys = try Keys()
        let notice = try Agentkeyring_V2_Notice(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-notice.pb")))
        let envelope = try CredentialSealing.openNotice(notice, deviceKeyID: keys.deviceID, with: keys.notice)
        let request = try CredentialSealing.parseRequest(envelope.request)
        #expect(request.reason == "You asked me to download October's invoice.")
        #expect(envelope.login.loginID == "login-example")
    }

    @Test("A request the asking machine signed in Go is shown; one the relay changed or made is refused")
    func requestFromGo() throws {
        let keys = try Keys()
        let members = try keys.members()
        let envelope = try Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-request.pb")))
        #expect(try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keys.deviceID)?.machineID == keys.machineID)
        var redirected = envelope
        var request = try CredentialSealing.parseRequest(envelope.request)
        request.loginID = "another-login"
        redirected.request = try request.serializedData()
        #expect(throws: CredentialSealingError.badSignature) { try CredentialSealing.verifySignedLeaseRequest(redirected, members: members, ownKeyID: keys.deviceID) }
        var unsigned = envelope
        unsigned.requestSignature = Data()
        #expect(throws: CredentialSealingError.badSignature) { try CredentialSealing.verifySignedLeaseRequest(unsigned, members: members, ownKeyID: keys.deviceID) }
    }

    @Test("A join proof made in Go checks in Swift")
    func joinProofFromGo() throws {
        let joining = try Agentkeyring_V2_JoinRequest(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-join.pb")))
        #expect(CredentialSealing.joinProof(secret: Data(repeating: 1, count: 32), joining: joining) == joining.proof)
        #expect(CredentialSealing.joinProof(secret: Data(repeating: 2, count: 32), joining: joining) != joining.proof)
    }

    @Test("A refusal made in Go checks in Swift")
    func refusalFromGo() throws {
        let refusal = try Agentkeyring_V2_JoinRefusal(serializedBytes: Data(contentsOf: Self.folder.appending(path: "go-refusal.pb")))
        let secret = Data(repeating: 1, count: 32)
        #expect(CredentialSealing.refusalKey(secret: secret, machineID: refusal.joinerID) == refusal.key)
        #expect(CredentialSealing.refusalReplyProof(secret: secret, machineID: refusal.joinerID, reply: refusal.reply) == refusal.replyProof)
        #expect(CredentialSealing.refusalReplyProof(secret: secret, machineID: refusal.joinerID, reply: "Something else.") != refusal.replyProof)
    }

    @Test("A members list in iCloud that pairs the iPhone's key ID with another key is not signed by the iPhone")
    func aListCannotPairADevicesIDWithAnotherKey() throws {
        let phone = P256.Signing.PrivateKey(), attacker = P256.Signing.PrivateKey()
        var forged = Agentkeyring_V2_Device()
        forged.kind = .iphone
        forged.keyID = CredentialSealing.keyID(phone.publicKey.x963Representation)
        forged.signingPublicKey = attacker.publicKey.x963Representation
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [forged]
        let signed = try CredentialSealing.signedDocument(members.serializedData(), by: forged.keyID) { try attacker.signature(for: $0).derRepresentation }
        #expect(throws: CredentialSealingError.badSignature) { try CredentialSealing.verifySignedMembers(signed, current: nil) }
    }
}
