// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Answering on the Watch: the chip opens the one login and seals it again for
// the asking machine, or the reply key signs a denial with the person's words.
// The Watch posts the signed answer to the relay itself, over HTTPS through
// the iPhone's connection, and checks it is talking to the relay by the key
// pinned in Members. The answer's signature is what the relay trusts.

#if os(watchOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import Security

public struct WatchAnswers: Sendable {
    let keys: WatchKeys
    let store: WatchStore

    public init(keys: WatchKeys = WatchKeys(), store: WatchStore = WatchStore()) { self.keys = keys; self.store = store }

    public func approve(_ request: WatchRequest) async throws -> Agentkeyring_V2_Lease {
        let saved = store.read()
        guard let members = saved.signedMembers else { throw WatchFailure.notSetUp }
        let work = try Agentkeyring_V2_Work(serializedBytes: request.work)
        guard work.hasSealedLogin else { throw WatchFailure.notInRequest }
        let parsed = try Sealing.parseRequest(work.request)
        guard let machine = members.machines.first(where: { $0.machineID == parsed.machineID }),
              let receiving = try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)
        else { throw WatchFailure.unknownMachine }
        let secret = try keys.open(work.sealedLogin)
        let upload = try Sealing.approve(request: work.request, secret: secret, sites: request.sites,
                                         receivingKey: receiving, signerKeyID: keys.keyID(), sign: keys.sign)
        return try await post(upload, saved: saved)
    }

    /// Every denial from the Watch is signed with its reply key, words or not.
    public func deny(_ request: WatchRequest, words: String) async throws -> Agentkeyring_V2_Lease {
        let saved = store.read()
        let work = try Agentkeyring_V2_Work(serializedBytes: request.work)
        let upload = try Sealing.deny(request: work.request, reply: words, signerKeyID: Sealing.keyID(keys.replyPublicKey()),
                                      sign: keys.signReply)
        return try await post(upload, saved: saved)
    }

    func post(_ upload: AnswerUpload, saved: WatchSaved) async throws -> Agentkeyring_V2_Lease {
        guard let text = saved.answerURL, let url = URL(string: text) else { throw WatchFailure.noAnswerAddress }
        guard let pinned = saved.signedMembers?.relayTlsPublicKey, !pinned.isEmpty else { throw WatchFailure.notSetUp }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = try upload.serializedData()
        let session = URLSession(configuration: .ephemeral, delegate: RelayPin(spki: pinned), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WatchFailure.relay(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return try Agentkeyring_V2_Lease(serializedBytes: data)
    }
}

/// Accepts the relay's self-signed certificate only if its key is the one
/// Members names.
final class RelayPin: NSObject, URLSessionDelegate, Sendable {
    let spki: Data
    init(spki: Data) { self.spki = spki }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              Self.spki(of: leaf) == spki else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// SubjectPublicKeyInfo DER of a P-256 certificate key.
    static func spki(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?, raw.count == 65 else { return nil }
        let prefix: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                               0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        return Data(prefix) + raw
    }
}
#endif
