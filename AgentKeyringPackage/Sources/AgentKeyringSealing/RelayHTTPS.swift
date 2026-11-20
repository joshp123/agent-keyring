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
    /// `timeout` is a deadline for the whole call, not only for silence on the connection.
    public static func post(_ body: Data, host: String, port: UInt16, path: String, pinned spki: Data,
                            timeout: TimeInterval = 15) async throws -> Data {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.port = Int(port); parts.path = path
        guard let url = parts.url, !spki.isEmpty else { throw Failure(status: 0, words: "no relay address or key") }
        let request = {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }()
        let session = URLSession(configuration: .ephemeral, delegate: Pin(spki: spki), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Failure(status: 0, words: "no answer within \(Int(timeout)) seconds")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
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

/// Telling the relay a request has reached this device, from a notification extension, around showing it.
/// The iPhone's and Apple Watch's extensions both go through here, so one line decides the order for both.
public enum ArrivalNote {
    /// The notification waits for the note, at most `deadline`. Set to false to show it first and send the
    /// note after, accepting that iOS may end the extension before the note is sent.
    public static let notificationWaits = true
    public static let deadline: TimeInterval = 1

    /// Sends the note, logs how long it took, and shows the notification, in the order above.
    public static func send(request id: String, log: DeviceLog, _ note: @escaping @Sendable () async throws -> Void,
                            show: @escaping @Sendable () -> Void) {
        Task {
            if !notificationWaits { show() }
            let start = Date()
            func elapsed() -> String { "\(Int(Date().timeIntervalSince(start) * 1000))" }
            do {
                try await note()
                log.note("push", "arrival sent", ["request": id, "ms": elapsed()])
            } catch {
                log.note("push", "arrival not sent", ["request": id, "ms": elapsed(), "error": "\(error)"])
            }
            if notificationWaits { show() }
        }
    }
}
