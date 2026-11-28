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
public typealias DeliveredCredentialEnvelope = Agentkeyring_V2_Delivery
public typealias DeliveredCredentialSecrets = Agentkeyring_V2_DeliveryContents
public typealias Members = Agentkeyring_V2_Members
public typealias Catalogue = Agentkeyring_V2_Catalogue

public enum CredentialSealingError: Error, Equatable {
    case wrongDomain, wrongLogin, notForThisRequest, badSignature, unknownSigner, staleRevision, expired
    /// A reply key signed something other than a denial, or a device changed its kind.
    case notAllowedForSigner
    case invalidNoticeKey
}

/// The sealing device's reply key: its key ID and a way to sign with it.
public struct PayloadReplySigner {
    public let keyID: String
    public let sign: (Data) throws -> Data
    public init(keyID: String, sign: @escaping (Data) throws -> Data) {
        self.keyID = keyID
        self.sign = sign
    }
}

public enum CredentialSealing {
    static let approvalSeconds: Int64 = 1800

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

    /// Seals one login to a device's opening key, or to an Automatic machine's
    /// receiving key, signed by the sealing device so no relay can forge it.
    /// `version` is when the secret was imported (Login.version): a reseal
    /// keeps the version of the copy it opened, or openers refuse it.
    public static func sealLogin(_ secret: LoginSecret, version: UInt64, to publicKey: P256.KeyAgreement.PublicKey, openerID: String,
        signer: PayloadReplySigner) throws -> SealedLogin {
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
    /// only for copies that never pass through the relay (the Mac's own). A
    /// login listed at version 0 has no copy anywhere: its password was deleted when it was Blocked.
    public static func verifySealedLogin(_ sealed: SealedLogin, members: Members, listed: Agentkeyring_V2_Login?) throws {
        if let listed, listed.loginID != sealed.loginID || listed.version != sealed.version || listed.version == 0 { throw CredentialSealingError.wrongLogin }
        try verifySignedDocument(sealedDocument(sealed), members: members, allowReplyKey: true)
    }

    /// A sealed copy only if this key signed it: a Mac's own copies, before it has members.
    public static func verifySealedLogin(_ sealed: SealedLogin, by keyID: String, publicKey: P256.Signing.PublicKey) throws {
        guard sealed.signerKeyID == keyID, let signature = try? P256.Signing.ECDSASignature(derRepresentation: sealed.signature),
            publicKey.isValidSignature(signature, for: sealedMessage(sealed)) else { throw CredentialSealingError.badSignature }
    }

    private static func sealedDocument(_ sealed: SealedLogin) -> SignedDocument {
        var document = SignedDocument()
        document.payload = sealedMessage(sealed)
        document.signerKeyID = sealed.signerKeyID
        document.signature = sealed.signature
        return document
    }

    /// An opened login only if it was sealed as the login it is shown or used as.
    public static func verifyOpenedLoginBinding(_ secret: LoginSecret, title: String, sites: [String], account: String) throws {
        guard secret.title == title, secret.sites == sites, secret.username == account else { throw CredentialSealingError.wrongLogin }
    }

    public static func openSealedLogin<Key: HPKEDiffieHellmanPrivateKey>(_ sealed: SealedLogin, with key: Key) throws -> LoginSecret {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: loginInfo, encapsulatedKey: sealed.encapsulatedKey)
        let secret = try LoginSecret(serializedBytes: recipient.open(sealed.ciphertext,
            authenticating: loginAAD(openerID: sealed.openerID, loginID: sealed.loginID)))
        guard secret.loginID == sealed.loginID else { throw CredentialSealingError.wrongLogin }
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
            if !d.noticePublicKey.isEmpty { parts.append(d.noticePublicKey) }
        case nil: break
        }
        let message = parts.reduce(Data()) { $0 + lengthPrefixed($1) }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    /// What only the inviter can send to refuse a machine's join (keyring.proto, JoinRequest.refusal_key_sha256).
    public static func refusalKey(secret: Data, machineID: String) -> Data {
        refusalMAC(secret: secret, parts: ["key", machineID])
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
    public static func buildSignedApproval(request requestBytes: Data, secret: LoginSecret, sites: [String],
        receivingKey: P256.KeyAgreement.PublicKey, signerKeyID: String, now: Date = .now,
        sign: (Data) throws -> Data) throws -> AnswerUpload {
        let request = try parseRequest(requestBytes)
        guard request.loginID == secret.loginID else { throw CredentialSealingError.notForThisRequest }
        let requestHash = sha256(requestBytes)
        let decided = Int64(now.timeIntervalSince1970)
        var contents = DeliveredCredentialSecrets()
        contents.requestID = request.requestID
        contents.loginID = secret.loginID
        contents.sites = sites
        contents.username = secret.username
        contents.password = secret.password
        contents.notAfterUnixSeconds = decided + approvalSeconds
        contents.oneTimeCodes = try OneTimeCodes.codes(for: secret, from: decided, until: contents.notAfterUnixSeconds)
        var sender = try HPKE.Sender(recipientKey: receivingKey, ciphersuite: suite, info: deliveryInfo)
        var delivery = DeliveredCredentialEnvelope()
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
        upload.answer = try signedDocument(answer.serializedData(), by: signerKeyID, sign: sign)
        upload.delivery = delivery
        return upload
    }

    /// Denies with the person's words, signed so the agent knows they are theirs.
    /// Sign with the reply key (no face or finger needed) and pass its id.
    public static func buildSignedDenial(request requestBytes: Data, reply: String, signerKeyID: String, now: Date = .now,
        sign: (Data) throws -> Data) throws -> AnswerUpload {
        _ = try parseRequest(requestBytes)
        var answer = Agentkeyring_V2_Answer()
        answer.domain = "agentkeyring.answer.v2"
        answer.requestSha256 = sha256(requestBytes)
        answer.choice = .deny
        answer.decidedUnixSeconds = Int64(now.timeIntervalSince1970)
        answer.reply = reply
        var upload = AnswerUpload()
        upload.answer = try signedDocument(answer.serializedData(), by: signerKeyID, sign: sign)
        return upload
    }

    /// Denies with no words: unsigned, so it needs no Face ID or Touch ID.
    public static func buildUnsignedDenial(requestID: String) -> AnswerUpload {
        var upload = AnswerUpload()
        upload.denyRequestID = requestID
        return upload
    }

    /// A request a device may show and answer: signed by the machine it names, with the key `members`
    /// lists as that machine's tls_public_key, so whatever carries it can neither make one up nor send the
    /// answer elsewhere, and naming an answer box at a relay this device may use. Returns the machine, or
    /// nil for this device's own practice request. Anything unsigned throws.
    @discardableResult
    public static func verifySignedLeaseRequest(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, members: Members, ownKeyID: String) throws -> Agentkeyring_V2_Machine? {
        let request = try parseRequest(envelope.request)
        if request.domain == practiceRequestDomain {
            try checkDevicePractice(envelope, request, members: members, ownKeyID: ownKeyID)
            return nil
        }
        let practice = !request.forDeviceKeyID.isEmpty && request.forDeviceKeyID == ownKeyID && request.loginID.isEmpty
        // A practice request goes only to the device it is for.
        guard request.forDeviceKeyID.isEmpty || practice else { throw CredentialSealingError.notAllowedForSigner }
        guard let machine = members.machines.first(where: { $0.machineID == request.machineID }) else { throw CredentialSealingError.unknownSigner }
        let signerKey = machine.tlsPublicKey
        guard let key = try? P256.Signing.PublicKey(derRepresentation: signerKey),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: envelope.requestSignature),
            key.isValidSignature(signature, for: envelope.request)
        else { throw CredentialSealingError.badSignature }
        guard RelayBoxProtocol.isValidID(request.answerBoxID), request.answerBoxKey.count == 32, RelayBoxClient(for: request) != nil else {
            throw CredentialSealingError.badSignature
        }
        return practice ? nil : machine
    }

    /// The password a request is for, from the signed Catalogue only: never the
    /// login the asking computer sends beside it, which it could dress as any site.
    /// A login missing from the Catalogue, or set to Blocked, can't be approved.
    public static func signedLogin(for request: KeyringRequest, in catalogue: Catalogue?) throws -> Agentkeyring_V2_Login {
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }) else { throw CredentialSealingError.wrongLogin }
        guard login.rule != .blocked else { throw CredentialSealingError.notAllowedForSigner }
        return login
    }

    public static func parseRequest(_ bytes: Data) throws -> KeyringRequest {
        let request = try KeyringRequest(serializedBytes: bytes)
        guard request.domain == "agentkeyring.request.v2" || request.domain == practiceRequestDomain else { throw CredentialSealingError.wrongDomain }
        return request
    }

    /// A practice request a device made (keyring.proto, Request.asker_key_id): the only request a device's
    /// signature is ever taken on.
    public static let practiceRequestDomain = "agentkeyring.practice-request.v2"

    /// A device's practice request for `target`, answered in a new box at `relay`, signed with the asking
    /// device's reply key: it names no login and no machine, so it can carry nothing but practice.
    public static func practiceRequest(id: String, for target: String, by asker: String, relay: RelayBoxClient = .configured,
                                       signReply: (Data) throws -> Data) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        var request = KeyringRequest()
        request.domain = practiceRequestDomain
        request.requestID = id
        request.askerKeyID = asker
        request.forDeviceKeyID = target
        request.askedUnixSeconds = Int64(Date().timeIntervalSince1970)
        request.answerByUnixSeconds = request.askedUnixSeconds + 600
        request.reason = "You asked me to download October’s invoice."
        request.agent = "Agent Keyring"
        request.project = "Practice"
        request.answerBoxID = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        request.answerBoxKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        if relay.url != RelayBoxProtocol.defaultURL { request.answerBoxURL = relay.url }
        var envelope = Agentkeyring_V2_SignedRequestEnvelope()
        envelope.request = try request.serializedData()
        envelope.requestSignature = try signReply(envelope.request)
        return envelope
    }

    /// The answer to a device's practice request, by `target`, the device it was for: signed by that
    /// device (either key; nothing is delivered, so a practice approval needs no Face ID behind it), over
    /// these exact bytes, approving or denying. Nil for anything else.
    public static func practiceAnswer(_ upload: AnswerUpload, for envelope: Agentkeyring_V2_SignedRequestEnvelope, target: String,
                                      members: Members) -> Agentkeyring_V2_Lease? {
        guard let request = try? parseRequest(envelope.request), request.domain == practiceRequestDomain, request.forDeviceKeyID == target,
              !upload.hasDelivery else { return nil }
        var lease = Agentkeyring_V2_Lease()
        lease.requestID = request.requestID
        lease.answerByUnixSeconds = request.answerByUnixSeconds
        if upload.denyRequestID == request.requestID {
            lease.state = .denied
            lease.answeredBy = members.devices.first { $0.keyID == target }?.label ?? ""
            return lease
        }
        guard let answer = try? Agentkeyring_V2_Answer(serializedBytes: upload.answer.payload), answer.domain == "agentkeyring.answer.v2",
              answer.requestSha256 == sha256(envelope.request), let signer = try? verifySignedDocument(upload.answer, members: members, allowReplyKey: true),
              signer.keyID == target else { return nil }
        lease.state = answer.choice == .approve ? .approved : .denied
        lease.reply = answer.reply
        lease.answeredBy = signer.label
        lease.notAfterUnixSeconds = answer.notAfterUnixSeconds
        return lease
    }

    /// A device's practice request for this device: signed by the reply key of a device in `members`, for
    /// this device, with no login, machine or Automatic, and answered in a box at a relay this device may use.
    static func checkDevicePractice(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, _ request: KeyringRequest, members: Members, ownKeyID: String) throws {
        guard let asker = members.devices.first(where: { $0.keyID == request.askerKeyID }),
              let key = try? P256.Signing.PublicKey(x963Representation: asker.replyPublicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: envelope.requestSignature),
              key.isValidSignature(signature, for: envelope.request) else { throw CredentialSealingError.badSignature }
        guard request.forDeviceKeyID == ownKeyID, request.loginID.isEmpty, request.machineID.isEmpty, !request.automatic,
              RelayBoxProtocol.isValidID(request.answerBoxID), request.answerBoxKey.count == 32, RelayBoxClient(for: request) != nil else {
            throw CredentialSealingError.badSignature
        }
    }

    /// Opens an approval on the asking machine, after checking who signed it.
    public static func openDelivery<Key: HPKEDiffieHellmanPrivateKey>(_ approval: Agentkeyring_V2_Approval,
        members: Members, with key: Key, now: Date = .now) throws -> DeliveredCredentialSecrets {
        let answer = try verifyRequestAnswer(approval, members: members)
        guard answer.choice == .approve, answer.deliverySha256 == sha256(approval.delivery.ciphertext) else { throw CredentialSealingError.notForThisRequest }
        guard answer.notAfterUnixSeconds > Int64(now.timeIntervalSince1970),
            answer.notAfterUnixSeconds <= answer.decidedUnixSeconds + approvalSeconds else { throw CredentialSealingError.expired }
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: deliveryInfo,
            encapsulatedKey: approval.delivery.encapsulatedKey)
        let contents = try DeliveredCredentialSecrets(serializedBytes: recipient.open(approval.delivery.ciphertext,
            authenticating: answer.requestSha256))
        let request = try parseRequest(approval.request)
        guard contents.requestID == request.requestID, contents.loginID == request.loginID else { throw CredentialSealingError.notForThisRequest }
        return contents
    }

    /// The answer in an approval, once its signature and request are checked.
    public static func verifyRequestAnswer(_ approval: Agentkeyring_V2_Approval, members: Members) throws -> Agentkeyring_V2_Answer {
        let answer = try Agentkeyring_V2_Answer(serializedBytes: approval.answer.payload)
        guard answer.domain == "agentkeyring.answer.v2" else { throw CredentialSealingError.wrongDomain }
        try verifySignedDocument(approval.answer, members: members, allowReplyKey: answer.choice == .deny)
        guard answer.requestSha256 == sha256(approval.request) else { throw CredentialSealingError.notForThisRequest }
        return answer
    }

    /// What a push shows, sealed to one device's notice key by the computer that asks.
    public static func sealNotice(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, to noticeKey: P256.KeyAgreement.PublicKey,
        deviceKeyID: String) throws -> Agentkeyring_V2_Notice {
        var sender = try HPKE.Sender(recipientKey: noticeKey, ciphersuite: suite, info: noticeInfo)
        var notice = Agentkeyring_V2_Notice()
        notice.ciphertext = try sender.seal(envelope.serializedData(), authenticating: Data(deviceKeyID.utf8))
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

    static func openPushCredential<Key: HPKEDiffieHellmanPrivateKey>(_ sealed: Agentkeyring_V2_SealedPushCredential,
        with key: Key) throws -> Agentkeyring_V2_PushCredential {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: pushCredentialInfo,
            encapsulatedKey: sealed.encapsulatedKey)
        return try Agentkeyring_V2_PushCredential(serializedBytes: recipient.open(sealed.ciphertext,
            authenticating: Data(sealed.openerID.utf8)))
    }

    /// What a push shows, opened with this device's notice key.
    public static func openNotice<Key: HPKEDiffieHellmanPrivateKey>(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String,
        with key: Key) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: noticeInfo, encapsulatedKey: notice.encapsulatedKey)
        return try Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: recipient.open(notice.ciphertext, authenticating: Data(deviceKeyID.utf8)))
    }

    // MARK: Signed documents

    public static func signedDocument(_ payload: Data, by signerKeyID: String, sign: (Data) throws -> Data) throws -> SignedDocument {
        var document = SignedDocument()
        document.payload = payload
        document.signature = try sign(payload)
        document.signerKeyID = signerKeyID
        return document
    }

    /// Checks the signature against a device in `members`, and returns that device.
    /// A reply key is accepted only where `allowReplyKey` says so: on a denial.
    @discardableResult
    public static func verifySignedDocument(_ document: SignedDocument, members: Members, allowReplyKey: Bool = false) throws -> Agentkeyring_V2_Device {
        let keyBytes: Data
        let device: Agentkeyring_V2_Device
        if let found = members.devices.first(where: { $0.keyID == document.signerKeyID }) {
            device = found
            keyBytes = found.signingPublicKey
        } else if let found = members.devices.first(where: { !$0.replyKeyID.isEmpty && $0.replyKeyID == document.signerKeyID }) {
            guard allowReplyKey else { throw CredentialSealingError.notAllowedForSigner }
            device = found
            keyBytes = found.replyPublicKey
        } else {
            throw CredentialSealingError.unknownSigner
        }
        // The key ID is the key's own hash: a list may not pair a device's ID with another key.
        guard keyID(keyBytes) == document.signerKeyID else { throw CredentialSealingError.badSignature }
        guard let key = try? P256.Signing.PublicKey(x963Representation: keyBytes),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: document.signature),
            key.isValidSignature(signature, for: document.payload)
        else { throw CredentialSealingError.badSignature }
        return device
    }

    /// A new Members, if signed by a device the current one lists and newer.
    /// With no current Members, the first must be signed by a device it lists.
    public static func verifySignedMembers(_ document: SignedDocument, current: Members?) throws -> Members {
        let next = try Members(serializedBytes: document.payload)
        guard next.domain == "agentkeyring.members.v2" else { throw CredentialSealingError.wrongDomain }
        if let current {
            guard next.revision > current.revision else { throw CredentialSealingError.staleRevision }
            try verifySignedDocument(document, members: current)
            // A device keeps the kind it joined as: the relay trusts a Mac and a Watch by kind.
            let kinds = Dictionary(current.devices.map { ($0.keyID, $0.kind) }, uniquingKeysWith: { first, _ in first })
            guard next.devices.allSatisfy({ kinds[$0.keyID] == nil || kinds[$0.keyID] == $0.kind }) else { throw CredentialSealingError.notAllowedForSigner }
        } else {
            try verifySignedDocument(document, members: next)
        }
        for device in next.devices where device.kind == .mac || device.kind == .iphone {
            guard (try? P256.KeyAgreement.PublicKey(x963Representation: device.noticePublicKey)) != nil else {
                throw CredentialSealingError.invalidNoticeKey
            }
        }
        return next
    }

    /// The other half of a Mac in `members`: for a Mac's device key ID, the computer its agents run on; for
    /// a computer, the Mac that approves on it. The two share one TLS key, and go together.
    public static func pairedMac(_ id: String, in members: Members) -> Set<String> {
        let macs = members.devices.filter { $0.kind == .mac && !$0.tlsPublicKey.isEmpty }
        if let device = macs.first(where: { $0.keyID == id }) {
            return Set(members.machines.filter { $0.tlsPublicKey == device.tlsPublicKey }.map(\.machineID))
        }
        guard let machine = members.machines.first(where: { $0.machineID == id }), !machine.tlsPublicKey.isEmpty else { return [] }
        return Set(macs.filter { $0.tlsPublicKey == machine.tlsPublicKey }.map(\.keyID))
    }

    /// A new Catalogue, if signed by a device in `members` and newer than the one held.
    public static func verifySignedCatalogue(_ document: SignedDocument, members: Members, current: Catalogue?) throws -> Catalogue {
        try verifySignedDocument(document, members: members)
        let catalogue = try Catalogue(serializedBytes: document.payload)
        guard catalogue.domain == "agentkeyring.catalogue.v2" else { throw CredentialSealingError.wrongDomain }
        if let current, catalogue.revision <= current.revision { throw CredentialSealingError.staleRevision }
        return catalogue
    }
}

/// Time-based one-time codes (RFC 6238), so the seed never leaves the device.
public enum OneTimeCodes {
    public static func codes(for secret: LoginSecret, from start: Int64, until end: Int64) throws -> [Agentkeyring_V2_TimedCode] {
        guard !secret.totpSeed.isEmpty else { return [] }
        let period = Int64(secret.totpPeriodSeconds == 0 ? 30 : secret.totpPeriodSeconds)
        let digits = Int(secret.totpDigits == 0 ? 6 : secret.totpDigits)
        guard period > 0, (6...8).contains(digits) else { throw CredentialSealingError.wrongLogin }
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
        default: throw CredentialSealingError.wrongLogin
        }
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let value = (UInt32(digest[offset] & 0x7f) << 24) | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        return String(format: "%0\(digits)u", value % modulus)
    }
}

extension Agentkeyring_V2_Login {
    /// Devices hold sealed copies of it: not Blocked, and its secret not
    /// deleted when it was (version 0 until the next export from Passwords).
    public var holdsSecret: Bool { rule != .blocked && version != 0 }
}

/// Shared request lifecycle rules for Mac, iPhone, and Apple Watch.
public enum CredentialRequestLifecycle {
    /// Monotonic outcome precedence shared across Mac, iPhone and Apple Watch:
    /// waiting -> approved -> terminal (ended, denied, cancelled), or waiting -> unanswered.
    /// A delayed approval or waiting notice can never resurrect a stopped or denied request.
    public static func canTransition(from previous: Agentkeyring_V2_LeaseState, to next: Agentkeyring_V2_LeaseState) -> Bool {
        switch next {
        case .waiting, .unspecified, .UNRECOGNIZED: return false
        case .approved, .denied, .cancelled, .ended, .unanswered, .expired, .released: break
        }
        switch previous {
        case .waiting, .unspecified, .UNRECOGNIZED: return true
        case .approved: return next != .approved && next != .unanswered
        case .denied, .cancelled, .ended, .unanswered, .expired, .released: return false
        }
    }

    public static func effectiveState(of envelope: Agentkeyring_V2_SignedRequestEnvelope, now: Date = .now) -> Agentkeyring_V2_LeaseState {
        let nowUnix = Int64(now.timeIntervalSince1970)
        let parsedRequest = try? CredentialSealing.parseRequest(envelope.request)
        if envelope.hasOutcome {
            var outcome = envelope.outcome
            if outcome.state == .waiting && outcome.answerByUnixSeconds == 0, let parsedRequest {
                outcome.answerByUnixSeconds = parsedRequest.answerByUnixSeconds
            }
            return effectiveState(of: outcome, now: now)
        }
        guard let parsedRequest else { return .unspecified }
        if parsedRequest.answerByUnixSeconds > 0 && nowUnix >= parsedRequest.answerByUnixSeconds {
            return .unanswered
        }
        return .waiting
    }

    public static func effectiveState(of lease: Agentkeyring_V2_Lease, now: Date = .now) -> Agentkeyring_V2_LeaseState {
        let nowUnix = Int64(now.timeIntervalSince1970)
        switch lease.state {
        case .waiting:
            return lease.answerByUnixSeconds > 0 && nowUnix >= lease.answerByUnixSeconds ? .unanswered : .waiting
        case .approved:
            return lease.notAfterUnixSeconds > 0 && nowUnix >= lease.notAfterUnixSeconds ? .expired : .approved
        case .unspecified, .denied, .unanswered, .ended, .cancelled, .expired, .released, .UNRECOGNIZED:
            return lease.state
        }
    }

    public static func isWaiting(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, now: Date = .now) -> Bool {
        effectiveState(of: envelope, now: now) == .waiting
    }

    public static func isWaiting(_ lease: Agentkeyring_V2_Lease, now: Date = .now) -> Bool {
        effectiveState(of: lease, now: now) == .waiting
    }
}

extension Agentkeyring_V2_LeaseState {
    /// True when no later event can reopen this request.
    public var isTerminal: Bool {
        switch self {
        case .denied, .cancelled, .ended, .unanswered, .expired, .released: true
        case .unspecified, .waiting, .approved, .UNRECOGNIZED: false
        }
    }

    /// Monotonic outcome precedence shared across Mac, iPhone and Apple Watch:
    /// waiting -> approved -> terminal (ended, denied, cancelled), or waiting -> unanswered.
    /// A delayed approval or waiting notice can never resurrect a stopped or denied request.
    public func canReplace(_ previous: Agentkeyring_V2_LeaseState) -> Bool {
        CredentialRequestLifecycle.canTransition(from: previous, to: self)
    }
}
