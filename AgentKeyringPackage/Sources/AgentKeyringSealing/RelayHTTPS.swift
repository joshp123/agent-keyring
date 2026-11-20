// Written by AI on 2026.11.18 by model claude opus 5.5; shared with the iPhone's notification extension on 2026.11.20.
//
// The relay's HTTPS door, for what cannot hold the framed connection: Apple
// Watch's answers, and the arrival notes the Watch and a locked iPhone's
// notification extension send. No client certificate; the relay is checked by
// the key pinned in Members.

import Foundation
import Security

public enum RelayHTTPS {
    /// POSTs a protobuf body to a path on the relay, pinned to its key in Members, and returns the reply.
    public static func post(_ body: Data, host: String, port: UInt16, path: String, pinned spki: Data,
                            timeout: TimeInterval = 15) async throws -> Data {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.port = Int(port); parts.path = path
        guard let url = parts.url, !spki.isEmpty else { throw Failure(status: 0, words: "no relay address or key") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = URLSession(configuration: .ephemeral, delegate: Pin(spki: spki), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(status: status, words: String(decoding: data.prefix(300), as: UTF8.self)) }
        return data
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: Int
        public let words: String
        public var description: String { "relay answered \(status): \(words)" }
    }

    /// Accepts the relay's self-signed certificate only if its key is the one Members names. The relay
    /// is reached by a private address with no certificate from a public authority, which App Transport
    /// Security would refuse before this check runs; each target that uses this therefore turns that
    /// default off in its Info.plist, and this pin is the check instead.
    final class Pin: NSObject, URLSessionDelegate, Sendable {
        let spki: Data
        init(spki: Data) { self.spki = spki }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            // The relay asks for a client certificate but does not need one here: what is posted carries its own proof.
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
                return (.performDefaultHandling, nil)
            }
            guard let trust = challenge.protectionSpace.serverTrust,
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
}
