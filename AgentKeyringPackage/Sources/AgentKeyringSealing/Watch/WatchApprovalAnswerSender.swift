// Written by AI on 2026.11.18 by model claude opus 5.5; edited on 2026.11.24.
//
// Answering on the Watch: the chip opens the Watch's own copy of the login
// (WatchCopiesStore.swift) and seals it again for the asking computer, or the reply
// key signs a denial with the person's words. The Watch puts the signed answer
// in the request's answer box itself, over HTTPS, on its own connection or
// through the iPhone's.

#if os(watchOS)
import AgentKeyringProtocol
import CryptoKit
import Foundation

public struct WatchApprovalAnswerSender: Sendable {
    let keys: WatchKeys
    let store: WatchKeychainStateStore
    let copies: WatchCopiesStore

    public init(keys: WatchKeys = WatchKeys(), store: WatchKeychainStateStore = WatchKeychainStateStore(), copies: WatchCopiesStore = WatchCopiesStore()) {
        self.keys = keys; self.store = store; self.copies = copies
    }

    public func sendApproval(_ request: WatchRequest) async throws -> Agentkeyring_V2_Lease {
        let saved = store.readWatchState()
        guard let members = saved.signedMembers else { throw WatchKeyringError.notSetUp }
        let envelope = try Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: request.envelope)
        // The practice request: a signed answer with nothing delivered.
        if request.isPractice {
            var answer = Agentkeyring_V2_Answer()
            answer.domain = "agentkeyring.answer.v2"
            answer.requestSha256 = CredentialSealing.sha256(envelope.request)
            answer.choice = .approve
            answer.decidedUnixSeconds = Int64(Date().timeIntervalSince1970)
            answer.notAfterUnixSeconds = answer.decidedUnixSeconds + 60
            var upload = AnswerUpload()
            upload.answer = try CredentialSealing.signedDocument(answer.serializedData(), by: keys.keyID(), sign: keys.signWithDeviceKey)
            return try await post(upload, for: envelope)
        }
        let parsed = try CredentialSealing.parseRequest(envelope.request)
        // The site Apple Watch showed and the sites the approval names both come from the signed Catalogue.
        let login = try CredentialSealing.signedLogin(for: parsed, in: saved.signedCatalogue)
        guard let machine = members.machines.first(where: { $0.machineID == parsed.machineID }),
              let receiving = try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)
        else { throw WatchKeyringError.unknownMachine }
        // Refuse approval if the login details, version, or recipient key changed while the card was on screen.
        if request.loginVersion > 0 {
            guard login.version == request.loginVersion,
                  login.title == request.loginTitle,
                  login.sites == request.sites,
                  login.account == request.account,
                  machine.receivingPublicKey == request.recipientKey else {
                throw WatchKeyringError.requestChanged
            }
        }
        guard let copy = copies.copy(of: login, for: try keys.keyID()) else { throw WatchKeyringError.notInRequest }
        // Nothing that carried it is trusted to say which copy is which: a device signed it, it is the current version, and it was sealed as this login.
        try CredentialSealing.verifySealedLogin(copy, members: members, listed: login)
        let secret = try keys.openSealedLogin(copy)
        try CredentialSealing.verifyOpenedLoginBinding(secret, title: login.title, sites: login.sites, account: login.account)
        let upload = try CredentialSealing.buildSignedApproval(request: envelope.request, secret: secret, sites: login.sites,
                                         receivingKey: receiving, signerKeyID: keys.keyID(), sign: keys.signWithDeviceKey)
        return try await post(upload, for: envelope)
    }

    /// Every denial from the Watch is signed with its reply key, words or not.
    public func sendDenial(_ request: WatchRequest, words: String) async throws -> Agentkeyring_V2_Lease {
        let envelope = try Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: request.envelope)
        let upload = try CredentialSealing.buildSignedDenial(request: envelope.request, reply: words, signerKeyID: CredentialSealing.keyID(keys.replyPublicKey()),
                                      sign: keys.signReply)
        return try await post(upload, for: envelope)
    }

    /// Into the request's answer box, retrying while the relay cannot be reached. The Lease returned is
    /// `.waiting`: sent, with the outcome to come by push.
    func post(_ upload: AnswerUpload, for envelope: Agentkeyring_V2_SignedRequestEnvelope) async throws -> Agentkeyring_V2_Lease {
        let request = try CredentialSealing.parseRequest(envelope.request)
        do { return try await AnswerBox.answer(upload, for: request, by: "Apple Watch") }
        catch is AnswerBox.AlreadyAnswered { throw WatchKeyringError.alreadyAnswered }
    }
}
#endif
