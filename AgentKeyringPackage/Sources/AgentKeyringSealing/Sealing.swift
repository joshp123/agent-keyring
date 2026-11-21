// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The sealed formats and signed documents of proto/agentkeyring/v2/keyring.proto,
// for the Mac, iPhone and Watch apps alike. The relay and the command have the
// same in Go (internal/keyring). Private keys stay with the caller: pass a
// Secure Enclave key, or a software key in tests.

import AgentKeyringProtocol
import CryptoKit
import Foundation

public typealias LoginSecret = Agentkeyring_V2_LoginSecret
public typealias SealedLogin = Agentkeyring_V2_SealedLogin
public typealias SignedDocument = Agentkeyring_V2_Signed
public typealias KeyringRequest = Agentkeyring_V2_Request
public typealias AnswerUpload = Agentkeyring_V2_AnswerUpload
public typealias Delivery = Agentkeyring_V2_Delivery
public typealias DeliveryContents = Agentkeyring_V2_DeliveryContents
public typealias Members = Agentkeyring_V2_Members
public typealias Catalogue = Agentkeyring_V2_Catalogue

public enum Sealing {
    public enum Failure: Error, Equatable {
        case wrongDomain, wrongLogin, notForThisRequest, badSignature, unknownSigner, staleRevision, expired
        /// A reply key signed something other than a denial, or a device changed its kind.
        case notAllowedForSigner
    }

    public static let approvalSeconds: Int64 = 1800

    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let loginInfo = Data("agentkeyring.login.v2".utf8)
    static let deliveryInfo = Data("agentkeyring.delivery.v2".utf8)
    static let noticeInfo = Data("agentkeyring.notice.v2".utf8)

    /// Lowercase hex SHA-256: the id of a key, given its public key bytes.
    public static func keyID(_ publicKeyBytes: Data) -> String {
        SHA256.hash(data: publicKeyBytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    // MARK: Sealed logins

    /// The sealing device's reply key: its key ID and a way to sign with it.
    public struct Signer {
        public let keyID: String
        public let sign: (Data) throws -> Data
        public init(keyID: String, sign: @escaping (Data) throws -> Data) {
            self.keyID = keyID
            self.sign = sign
        }
    }

    /// Seals one login to a device's opening key, or to an Automatic machine's
    /// receiving key, signed by the sealing device so no relay can forge it.
    /// `version` is when the secret was imported (Login.version): a reseal
    /// keeps the version of the copy it opened, or openers refuse it.
    public static func seal(_ secret: LoginSecret, version: UInt64, to publicKey: P256.KeyAgreement.PublicKey, openerID: String,
        signer: Signer) throws -> SealedLogin {
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: suite, info: loginInfo)
        var sealed = SealedLogin()
        sealed.loginID = secret.loginID
        sealed.openerID = openerID
        sealed.ciphertext = try sender.seal(secret.serializedData(), authenticating: loginAAD(openerID: openerID, loginID: secret.loginID))
        sealed.encapsulatedKey = sender.encapsulatedKey
        sealed.version = version
        sealed.signerKeyID = signer.keyID
        sealed.signature = try signer.sign(sealedMessage(sealed))
        return sealed
    }

    static func sealedMessage(_ sealed: SealedLogin) -> Data {
        var version = sealed.version.bigEndian
        return [Data("agentkeyring.sealed.v2".utf8), Data(sealed.loginID.utf8), Data(sealed.openerID.utf8), sealed.encapsulatedKey, sealed.ciphertext]
            .reduce(Data()) { $0 + lengthPrefixed($1) } + withUnsafeBytes(of: &version) { Data($0) }
    }

    /// A sealed copy only if a device in `members` signed it and, given the
    /// login from a signed catalogue, it is that login's current version: a
    /// relay can neither forge, relabel nor roll back a copy. Pass no login
    /// only for copies that never pass through the relay (the Mac's own).
    public static func checkSealed(_ sealed: SealedLogin, members: Members, listed: Agentkeyring_V2_Login?) throws {
        if let listed, listed.loginID != sealed.loginID || listed.version != sealed.version { throw Failure.wrongLogin }
        try verify(sealedDocument(sealed), members: members, allowReplyKey: true)
    }

    /// A sealed copy only if this key signed it: a Mac's own copies, before it has members.
    public static func checkSealed(_ sealed: SealedLogin, by keyID: String, publicKey: P256.Signing.PublicKey) throws {
        guard sealed.signerKeyID == keyID, let signature = try? P256.Signing.ECDSASignature(derRepresentation: sealed.signature),
            publicKey.isValidSignature(signature, for: sealedMessage(sealed)) else { throw Failure.badSignature }
    }

    private static func sealedDocument(_ sealed: SealedLogin) -> SignedDocument {
        var document = SignedDocument()
        document.payload = sealedMessage(sealed)
        document.signerKeyID = sealed.signerKeyID
        document.signature = sealed.signature
        return document
    }

    /// An opened login only if it was sealed as the login it is shown or used as.
    public static func checkBound(_ secret: LoginSecret, title: String, sites: [String], account: String) throws {
        guard secret.title == title, secret.sites == sites, secret.username == account else { throw Failure.wrongLogin }
    }

    public static func open<Key: HPKEDiffieHellmanPrivateKey>(_ sealed: SealedLogin, with key: Key) throws -> LoginSecret {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: loginInfo, encapsulatedKey: sealed.encapsulatedKey)
        let secret = try LoginSecret(serializedBytes: recipient.open(sealed.ciphertext,
            authenticating: loginAAD(openerID: sealed.openerID, loginID: sealed.loginID)))
        guard secret.loginID == sealed.loginID else { throw Failure.wrongLogin }
        return secret
    }

    static func loginAAD(openerID: String, loginID: String) -> Data {
        lengthPrefixed(Data(openerID.utf8)) + lengthPrefixed(Data(loginID.utf8))
    }

    static func lengthPrefixed(_ part: Data) -> Data {
        var length = UInt32(part.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + part
    }

    // MARK: Joining

    /// Proves a joiner holds an invitation's secret (keyring.proto, JoinRequest.proof).
    public static func joinProof(secret: Data, joining: Agentkeyring_V2_JoinRequest) -> Data {
        var parts: [Data] = [Data("agentkeyring.join.v2".utf8)]
        switch joining.joining {
        case let .machine(m)?:
            parts += [Data("machine".utf8), Data(m.label.utf8), Data(m.machineID.utf8), m.tlsPublicKey, m.receivingPublicKey]
        case let .device(d)?:
            parts += [Data("device".utf8), Data(d.label.utf8), Data(d.keyID.utf8), Data(String(d.kind.rawValue).utf8),
                d.signingPublicKey, d.openingPublicKey, d.tlsPublicKey, Data(d.replyKeyID.utf8), d.replyPublicKey]
        case nil: break
        }
        let message = parts.reduce(Data()) { $0 + lengthPrefixed($1) }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    /// What only the inviter can send to refuse a machine's join (keyring.proto, JoinRequest.refusal_key_sha256).
    public static func refusalKey(secret: Data, machineID: String) -> Data {
        refusalMAC(secret: secret, parts: ["key", machineID])
    }

    /// What a first members list carries to show its device got the relay's
    /// one-time secret from the relay's own computer (keyring.proto, Members.setup_proof).
    public static func setupProof(secret: Data, relaySPKI: Data, firstDeviceKeyID: String) -> Data {
        var message = Data("agentkeyring.setup.v2".utf8)
        message.append(relaySPKI)
        message.append(Data(firstDeviceKeyID.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    /// Binds the inviter's words to a refusal (keyring.proto, JoinRefusal.reply_proof).
    public static func refusalReplyProof(secret: Data, machineID: String, reply: String) -> Data {
        refusalMAC(secret: secret, parts: ["reply", machineID, reply])
    }

    private static func refusalMAC(secret: Data, parts: [String]) -> Data {
        let message = (["agentkeyring.refusal.v2"] + parts).reduce(Data()) { $0 + lengthPrefixed(Data($1.utf8)) }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    // MARK: Answers

    /// Approves a request: the opened login, sealed again for the asking
    /// machine for 30 minutes, with an answer signed by this device.
    /// `sign` signs bytes with the device's signing key, returning DER.
    public static func approve(request requestBytes: Data, secret: LoginSecret, sites: [String],
        receivingKey: P256.KeyAgreement.PublicKey, signerKeyID: String, now: Date = .now,
        sign: (Data) throws -> Data) throws -> AnswerUpload {
        let request = try parseRequest(requestBytes)
        guard request.loginID == secret.loginID else { throw Failure.notForThisRequest }
        let requestHash = sha256(requestBytes)
        let decided = Int64(now.timeIntervalSince1970)
        var contents = DeliveryContents()
        contents.requestID = request.requestID
        contents.loginID = secret.loginID
        contents.sites = sites
        contents.username = secret.username
        contents.password = secret.password
        contents.notAfterUnixSeconds = decided + approvalSeconds
        contents.oneTimeCodes = try OneTimeCodes.codes(for: secret, from: decided, until: contents.notAfterUnixSeconds)
        var sender = try HPKE.Sender(recipientKey: receivingKey, ciphersuite: suite, info: deliveryInfo)
        var delivery = Delivery()
        delivery.ciphertext = try sender.seal(contents.serializedData(), authenticating: requestHash)
        delivery.encapsulatedKey = sender.encapsulatedKey
        var answer = Agentkeyring_V2_Answer()
        answer.domain = "agentkeyring.answer.v2"
        answer.requestSha256 = requestHash
        answer.choice = .approve
        answer.decidedUnixSeconds = decided
        answer.notAfterUnixSeconds = contents.notAfterUnixSeconds
        answer.deliverySha256 = sha256(delivery.ciphertext)
        var upload = AnswerUpload()
        upload.answer = try signed(answer.serializedData(), by: signerKeyID, sign: sign)
        upload.delivery = delivery
        return upload
    }

    /// Denies with the person's words, signed so the agent knows they are theirs.
    /// Sign with the reply key (no face or finger needed) and pass its id.
    public static func deny(request requestBytes: Data, reply: String, signerKeyID: String, now: Date = .now,
        sign: (Data) throws -> Data) throws -> AnswerUpload {
        _ = try parseRequest(requestBytes)
        var answer = Agentkeyring_V2_Answer()
        answer.domain = "agentkeyring.answer.v2"
        answer.requestSha256 = sha256(requestBytes)
        answer.choice = .deny
        answer.decidedUnixSeconds = Int64(now.timeIntervalSince1970)
        answer.reply = reply
        var upload = AnswerUpload()
        upload.answer = try signed(answer.serializedData(), by: signerKeyID, sign: sign)
        return upload
    }

    /// Denies with no words: unsigned, so it needs no Face ID or Touch ID.
    public static func plainDeny(requestID: String) -> AnswerUpload {
        var upload = AnswerUpload()
        upload.denyRequestID = requestID
        return upload
    }

    /// A request a device may show and answer: signed by the machine it names, with that machine's TLS
    /// key as `members` lists it, so the relay can neither make one up nor send the answer elsewhere. Its
    /// answer door, if named, must serve with that same key. A practice request for this device may also
    /// be signed by the relay's TLS key (one a device asked the relay for). Returns the machine, or nil for
    /// this device's own practice request. Anything unsigned throws.
    @discardableResult
    public static func checkRequest(_ work: Agentkeyring_V2_Work, members: Members, ownKeyID: String) throws -> Agentkeyring_V2_Machine? {
        let request = try parseRequest(work.request)
        let practice = !request.forDeviceKeyID.isEmpty && request.forDeviceKeyID == ownKeyID && request.loginID.isEmpty
        let machine = members.machines.first { $0.machineID == request.machineID }
        let signerKey: Data
        if let machine { signerKey = machine.tlsPublicKey }
        else if practice, request.machineID.isEmpty { signerKey = members.relayTlsPublicKey }
        else { throw Failure.unknownSigner }
        guard let key = try? P256.Signing.PublicKey(derRepresentation: signerKey),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: work.requestSignature),
            key.isValidSignature(signature, for: work.request)
        else { throw Failure.badSignature }
        if !practice || !request.answerAddress.isEmpty {
            guard answerDoor(request) != nil, request.answerTlsPublicKey == signerKey else { throw Failure.badSignature }
        }
        return practice ? nil : machine
    }

    /// Where a device posts its answer, arrival and Stop: the asking machine's door, a Tailscale IP and
    /// port, pinned to its key in Members. Nil when the request names none or a name instead of an address.
    public static func answerDoor(_ request: KeyringRequest) -> (host: String, port: UInt16, key: Data)? {
        guard !request.answerAddress.isEmpty, let colon = request.answerAddress.lastIndex(of: ":"),
              let port = UInt16(request.answerAddress[request.answerAddress.index(after: colon)...]) else { return nil }
        var host = String(request.answerAddress[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard Tailnet.isAddress(host), !request.answerTlsPublicKey.isEmpty else { return nil }
        return (host, port, request.answerTlsPublicKey)
    }

    /// The password a request is for, from the signed Catalogue only: never the
    /// login the relay sends beside it, which the relay could dress as any site.
    /// A login missing from the Catalogue, or set to Blocked, can't be approved.
    public static func signedLogin(for request: KeyringRequest, in catalogue: Catalogue?) throws -> Agentkeyring_V2_Login {
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }) else { throw Failure.wrongLogin }
        guard login.rule != .blocked else { throw Failure.notAllowedForSigner }
        return login
    }

    public static func parseRequest(_ bytes: Data) throws -> KeyringRequest {
        let request = try KeyringRequest(serializedBytes: bytes)
        guard request.domain == "agentkeyring.request.v2" else { throw Failure.wrongDomain }
        return request
    }

    /// Opens an approval on the asking machine, after checking who signed it.
    public static func openDelivery<Key: HPKEDiffieHellmanPrivateKey>(_ approval: Agentkeyring_V2_Approval,
        members: Members, with key: Key, now: Date = .now) throws -> DeliveryContents {
        let answer = try verifiedAnswer(approval, members: members)
        guard answer.choice == .approve, answer.deliverySha256 == sha256(approval.delivery.ciphertext) else { throw Failure.notForThisRequest }
        guard answer.notAfterUnixSeconds > Int64(now.timeIntervalSince1970),
            answer.notAfterUnixSeconds <= answer.decidedUnixSeconds + approvalSeconds else { throw Failure.expired }
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: deliveryInfo,
            encapsulatedKey: approval.delivery.encapsulatedKey)
        let contents = try DeliveryContents(serializedBytes: recipient.open(approval.delivery.ciphertext,
            authenticating: answer.requestSha256))
        let request = try parseRequest(approval.request)
        guard contents.requestID == request.requestID, contents.loginID == request.loginID else { throw Failure.notForThisRequest }
        return contents
    }

    /// The answer in an approval, once its signature and request are checked.
    public static func verifiedAnswer(_ approval: Agentkeyring_V2_Approval, members: Members) throws -> Agentkeyring_V2_Answer {
        let answer = try Agentkeyring_V2_Answer(serializedBytes: approval.answer.payload)
        guard answer.domain == "agentkeyring.answer.v2" else { throw Failure.wrongDomain }
        try verify(approval.answer, members: members, allowReplyKey: answer.choice == .deny)
        guard answer.requestSha256 == sha256(approval.request) else { throw Failure.notForThisRequest }
        return answer
    }

    /// What a push shows, sealed to one device's notice key by the computer that asks.
    public static func sealNotice(_ work: Agentkeyring_V2_Work, to noticeKey: P256.KeyAgreement.PublicKey,
        deviceKeyID: String) throws -> Agentkeyring_V2_Notice {
        var sender = try HPKE.Sender(recipientKey: noticeKey, ciphersuite: suite, info: noticeInfo)
        var notice = Agentkeyring_V2_Notice()
        notice.ciphertext = try sender.seal(work.serializedData(), authenticating: Data(deviceKeyID.utf8))
        notice.encapsulatedKey = sender.encapsulatedKey
        return notice
    }

    static let pushCredentialInfo = Data("agentkeyring.push-credential.v2".utf8)

    /// Apple's push credential, sealed to a computer's receiving key as it joins.
    public static func sealPushCredential(_ credential: Agentkeyring_V2_PushCredential, to receivingKey: P256.KeyAgreement.PublicKey,
        machineID: String) throws -> Agentkeyring_V2_SealedPushCredential {
        var sender = try HPKE.Sender(recipientKey: receivingKey, ciphersuite: suite, info: pushCredentialInfo)
        var sealed = Agentkeyring_V2_SealedPushCredential()
        sealed.openerID = machineID
        sealed.ciphertext = try sender.seal(credential.serializedData(), authenticating: Data(machineID.utf8))
        sealed.encapsulatedKey = sender.encapsulatedKey
        return sealed
    }

    public static func openPushCredential<Key: HPKEDiffieHellmanPrivateKey>(_ sealed: Agentkeyring_V2_SealedPushCredential,
        with key: Key) throws -> Agentkeyring_V2_PushCredential {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: pushCredentialInfo,
            encapsulatedKey: sealed.encapsulatedKey)
        return try Agentkeyring_V2_PushCredential(serializedBytes: recipient.open(sealed.ciphertext,
            authenticating: Data(sealed.openerID.utf8)))
    }

    /// What a push shows, opened with this device's notice key.
    public static func openNotice<Key: HPKEDiffieHellmanPrivateKey>(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String,
        with key: Key) throws -> Agentkeyring_V2_Work {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: noticeInfo, encapsulatedKey: notice.encapsulatedKey)
        return try Agentkeyring_V2_Work(serializedBytes: recipient.open(notice.ciphertext, authenticating: Data(deviceKeyID.utf8)))
    }

    // MARK: Signed documents

    public static func signed(_ payload: Data, by signerKeyID: String, sign: (Data) throws -> Data) throws -> SignedDocument {
        var document = SignedDocument()
        document.payload = payload
        document.signature = try sign(payload)
        document.signerKeyID = signerKeyID
        return document
    }

    /// Checks the signature against a device in `members`, and returns that device.
    /// A reply key is accepted only where `allowReplyKey` says so: on a denial.
    @discardableResult
    public static func verify(_ document: SignedDocument, members: Members, allowReplyKey: Bool = false) throws -> Agentkeyring_V2_Device {
        let keyBytes: Data
        let device: Agentkeyring_V2_Device
        if let found = members.devices.first(where: { $0.keyID == document.signerKeyID }) {
            device = found
            keyBytes = found.signingPublicKey
        } else if let found = members.devices.first(where: { !$0.replyKeyID.isEmpty && $0.replyKeyID == document.signerKeyID }) {
            guard allowReplyKey else { throw Failure.notAllowedForSigner }
            device = found
            keyBytes = found.replyPublicKey
        } else {
            throw Failure.unknownSigner
        }
        guard let key = try? P256.Signing.PublicKey(x963Representation: keyBytes),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: document.signature),
            key.isValidSignature(signature, for: document.payload)
        else { throw Failure.badSignature }
        return device
    }

    /// A new Members, if signed by a device the current one lists and newer.
    /// With no current Members, the first must be signed by a device it lists.
    public static func verifiedMembers(_ document: SignedDocument, current: Members?) throws -> Members {
        let next = try Members(serializedBytes: document.payload)
        guard next.domain == "agentkeyring.members.v2" else { throw Failure.wrongDomain }
        if let current {
            guard next.revision > current.revision else { throw Failure.staleRevision }
            try verify(document, members: current)
            // A device keeps the kind it joined as: the relay trusts a Mac and a Watch by kind.
            let kinds = Dictionary(current.devices.map { ($0.keyID, $0.kind) }, uniquingKeysWith: { first, _ in first })
            guard next.devices.allSatisfy({ kinds[$0.keyID] == nil || kinds[$0.keyID] == $0.kind }) else { throw Failure.notAllowedForSigner }
        } else {
            try verify(document, members: next)
        }
        return next
    }

    /// A new Catalogue, if signed by a device in `members` and newer than the one held.
    public static func verifiedCatalogue(_ document: SignedDocument, members: Members, current: Catalogue?) throws -> Catalogue {
        try verify(document, members: members)
        let catalogue = try Catalogue(serializedBytes: document.payload)
        guard catalogue.domain == "agentkeyring.catalogue.v2" else { throw Failure.wrongDomain }
        if let current, catalogue.revision <= current.revision { throw Failure.staleRevision }
        return catalogue
    }
}

/// Time-based one-time codes (RFC 6238), so the seed never leaves the device.
public enum OneTimeCodes {
    public static func codes(for secret: LoginSecret, from start: Int64, until end: Int64) throws -> [Agentkeyring_V2_TimedCode] {
        guard !secret.totpSeed.isEmpty else { return [] }
        let period = Int64(secret.totpPeriodSeconds == 0 ? 30 : secret.totpPeriodSeconds)
        let digits = Int(secret.totpDigits == 0 ? 6 : secret.totpDigits)
        guard period > 0, (6...8).contains(digits) else { throw Sealing.Failure.wrongLogin }
        var codes: [Agentkeyring_V2_TimedCode] = []
        var step = start / period * period
        while step < end {
            var code = Agentkeyring_V2_TimedCode()
            code.validFromUnixSeconds = step
            code.validUntilUnixSeconds = min(step + period, end)
            code.code = try self.code(seed: secret.totpSeed, counter: UInt64(step / period), digits: digits, algorithm: secret.totpAlgorithm)
            codes.append(code)
            step += period
        }
        return codes
    }

    static func code(seed: Data, counter: UInt64, digits: Int, algorithm: String) throws -> String {
        var counter = counter.bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: seed)
        let digest: Data = switch algorithm {
        case "", "SHA1": Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case "SHA256": Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "SHA512": Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default: throw Sealing.Failure.wrongLogin
        }
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let value = (UInt32(digest[offset] & 0x7f) << 24) | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        return String(format: "%0\(digits)u", value % modulus)
    }
}
