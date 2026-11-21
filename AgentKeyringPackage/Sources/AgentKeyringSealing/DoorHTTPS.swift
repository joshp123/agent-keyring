// Written by AI on 2026.11.18 by model claude opus 5.5; for the doors of the direct protocol on 2026.11.21.
//
// HTTPS to a door on the tailnet: the asking computer's (answers, arrival
// notes, Stop) and the Mac's (joining, lists, copies, practice, logs). Each is
// reached by a Tailscale IP address and checked by the key pinned in Members or
// in the Mac's join card, never by a public certificate. The Mac's door also
// asks for this device's TLS client certificate.

import Foundation
import Security

public enum DoorHTTPS {
    /// Sends a request to a path on a door, pinned to its key, and returns the reply. `timeout` is a
    /// deadline for the whole call, not only for silence on the connection. `client`: this device's TLS
    /// identity, for the Mac's door.
    public static func send(_ method: String = "POST", _ body: Data? = nil, host: String, port: UInt16, path: String,
                            query: [URLQueryItem] = [], pinned spki: Data, client: SecIdentity? = nil,
                            timeout: TimeInterval = 15) async throws -> Data {
        guard Tailnet.isAddress(host) else { throw Failure(status: 0, words: "\(host) is not a Tailscale address") }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.port = Int(port); parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url, !spki.isEmpty else { throw Failure(status: 0, words: "no door address or key") }
        let request = {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            if let body {
                request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            return request
        }()
        let session = URLSession(configuration: .ephemeral, delegate: Pin(spki: spki, client: client), delegateQueue: nil)
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

    public static func post(_ body: Data, host: String, port: UInt16, path: String, pinned spki: Data,
                            timeout: TimeInterval = 15) async throws -> Data {
        try await send("POST", body, host: host, port: port, path: path, pinned: spki, timeout: timeout)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: Int
        public let words: String
        public var description: String { status == 0 ? words : "the door answered \(status): \(words)" }
    }

    /// Accepts the door's self-signed certificate only if its key is the pinned one, and offers this
    /// device's client certificate when asked for one. The door has no certificate from a public authority,
    /// which App Transport Security would refuse before this check runs; each target that uses this therefore
    /// turns that default off in its Info.plist, and this pin is the check instead.
    final class Pin: NSObject, URLSessionDelegate, @unchecked Sendable {
        let spki: Data
        let client: SecIdentity?
        init(spki: Data, client: SecIdentity?) { self.spki = spki; self.client = client }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodClientCertificate:
                guard let client else { return (.performDefaultHandling, nil) }
                return (.useCredential, URLCredential(identity: client, certificates: nil, persistence: .forSession))
            case NSURLAuthenticationMethodServerTrust:
                guard let trust = challenge.protectionSpace.serverTrust,
                      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                      Self.spki(of: leaf) == spki else { return (.cancelAuthenticationChallenge, nil) }
                return (.useCredential, URLCredential(trust: trust))
            default:
                return (.performDefaultHandling, nil)
            }
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

/// Addresses on the tailnet. Every door is named by the Tailscale IP its computer read from Tailscale:
/// never a host name, which anything on the network path could answer for.
public enum Tailnet {
    /// Tests that stand a door up in their own process on 127.0.0.1 turn this on. Nothing else does.
    nonisolated(unsafe) public static var acceptsLoopbackForTests = false

    /// 100.64.0.0/10, or fd7a:115c:a1e0::/48.
    public static func isAddress(_ host: String) -> Bool {
        if acceptsLoopbackForTests, host == "127.0.0.1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        if parts.count == 4, host.split(separator: ".").count == 4 { return parts[0] == 100 && (64...127).contains(parts[1]) }
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return bytes.prefix(6) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }
}

/// Telling the asking computer a request has reached this device, from a notification extension, around showing it.
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
