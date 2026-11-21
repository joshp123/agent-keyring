// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Answering on the Watch: the chip opens the one login the push carried and
// seals it again for the asking computer, or the reply key signs a denial with
// the person's words. The Watch posts the signed answer to the asking
// computer's door itself, over HTTPS through the iPhone's connection, pinned
// to that computer's key in Members.

#if os(watchOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation

public struct WatchAnswers: Sendable {
    let keys: WatchKeys
    let store: WatchStore

    public init(keys: WatchKeys = WatchKeys(), store: WatchStore = WatchStore()) { self.keys = keys; self.store = store }

    public func approve(_ request: WatchRequest) async throws -> Agentkeyring_V2_Lease {
        let saved = store.read()
        guard let members = saved.signedMembers else { throw WatchFailure.notSetUp }
        let work = try Agentkeyring_V2_Work(serializedBytes: request.work)
        // The practice request: a signed answer with nothing delivered.
        if request.isPractice {
            var answer = Agentkeyring_V2_Answer()
            answer.domain = "agentkeyring.answer.v2"
            answer.requestSha256 = Sealing.sha256(work.request)
            answer.choice = .approve
            answer.decidedUnixSeconds = Int64(Date().timeIntervalSince1970)
            answer.notAfterUnixSeconds = answer.decidedUnixSeconds + 60
            var upload = AnswerUpload()
            upload.answer = try Sealing.signed(answer.serializedData(), by: keys.keyID(), sign: keys.sign)
            return try await post(upload, for: work)
        }
        guard work.hasSealedLogin else { throw WatchFailure.notInRequest }
        let parsed = try Sealing.parseRequest(work.request)
        // The site Apple Watch showed and the sites the approval names both come from the signed Catalogue.
        let login = try Sealing.signedLogin(for: parsed, in: saved.signedCatalogue)
        guard let machine = members.machines.first(where: { $0.machineID == parsed.machineID }),
              let receiving = try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)
        else { throw WatchFailure.unknownMachine }
        // The relay is not trusted to say which copy is which: a device signed it, it is the current version, and it was sealed as this login.
        try Sealing.checkSealed(work.sealedLogin, members: members, listed: login)
        let secret = try keys.open(work.sealedLogin)
        try Sealing.checkBound(secret, title: login.title, sites: login.sites, account: login.account)
        let upload = try Sealing.approve(request: work.request, secret: secret, sites: login.sites,
                                         receivingKey: receiving, signerKeyID: keys.keyID(), sign: keys.sign)
        return try await post(upload, for: work)
    }

    /// Every denial from the Watch is signed with its reply key, words or not.
    public func deny(_ request: WatchRequest, words: String) async throws -> Agentkeyring_V2_Lease {
        let work = try Agentkeyring_V2_Work(serializedBytes: request.work)
        let upload = try Sealing.deny(request: work.request, reply: words, signerKeyID: Sealing.keyID(keys.replyPublicKey()),
                                      sign: keys.signReply)
        return try await post(upload, for: work)
    }

    /// Tells the asking computer this request has reached this Apple Watch, so it can say where it is.
    /// Signed with the reply key, which works while the Watch is unlocked. It gives up after `ArrivalNote.deadline`.
    public func arrived(_ request: WatchRequest) async throws {
        var arrival = Agentkeyring_V2_Arrival()
        arrival.domain = "agentkeyring.arrival.v2"
        arrival.requestID = request.id
        arrival.deviceKeyID = try keys.keyID()
        arrival.arrivedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signed = try Sealing.signed(arrival.serializedData(), by: Sealing.keyID(keys.replyPublicKey()), sign: keys.signReply)
        try await AnswerDoor.arrived(signed, at: door(request.work))
    }

    /// To the asking computer's door, retrying while it cannot connect. The reply is the request's Lease:
    /// this answer's, or the one that already ended it.
    func post(_ upload: AnswerUpload, for work: Agentkeyring_V2_Work) async throws -> Agentkeyring_V2_Lease {
        do { return try await AnswerDoor.answer(upload, at: door(work.serializedData())) }
        catch let refused as AnswerDoor.Refused { throw WatchFailure.refused(refused.words) }
    }

    private func door(_ workBytes: Data) throws -> AnswerDoor.Door {
        let work = try Agentkeyring_V2_Work(serializedBytes: workBytes)
        guard let door = Sealing.answerDoor(try Sealing.parseRequest(work.request)) else { throw WatchFailure.noAnswerAddress }
        return door
    }
}
#endif
