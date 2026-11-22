// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// A door: HTTPS with this computer's TLS key, HTTP/1.1 over TLS 1.3, one
// request per connection (keyring.proto, "Direct: no relay"). A door either
// requires a client certificate or asks for none: macOS's TLS cannot ask for
// one and go on without it, so the Mac keeps two doors, its answer door for
// the Apple Watch and a locked iPhone, which have none, and its members' door.

import AgentKeyringRelaySupport
import AgentKeyringSealing
import Darwin
import Foundation
import Network
import Security

public struct DoorRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    /// By lowercase name.
    public let headers: [String: String]
    public let body: Data
    /// The client certificate's SubjectPublicKeyInfo, if one was sent.
    public let peerSPKI: Data?
}

public struct DoorReply: Sendable {
    public let status: Int
    public let body: Data
    let isText: Bool

    public static func ok(_ body: Data = Data()) -> DoorReply { DoorReply(status: 200, body: body, isText: false) }
    public static func text(_ words: String) -> DoorReply { DoorReply(status: 200, body: Data(words.utf8), isText: true) }
    /// 400, 403, 404 or 503, with a sentence a person or an agent can act on.
    public static func refused(_ status: Int, _ words: String) -> DoorReply { DoorReply(status: status, body: Data(words.utf8), isText: true) }
}

public final class DoorServer: @unchecked Sendable {
    public typealias Handler = @Sendable (DoorRequest) async -> DoorReply
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.agentkeyring.door")
    private let handle: Handler
    private let onClosed: (@Sendable (Error) -> Void)?
    private static let largestBody = 16 * 1024 * 1024
    private static let largestHead = 16 * 1024

    public init(identity: RelayTLSIdentity, host: String, port: UInt16, requireClientCertificate: Bool = false,
        onClosed: (@Sendable (Error) -> Void)? = nil,
        handle: @escaping Handler) throws {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, sec_identity_create(identity.identity)!)
        if requireClientCertificate {
            sec_protocol_options_set_peer_authentication_required(options, true)
            sec_protocol_options_set_verify_block(options, { _, trust, complete in
                // Any one P-256 certificate: each route checks the key it needs.
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
                complete(chain.count == 1 && (try? RelayTLSIdentity.spki(certificate: chain[0])) != nil)
            }, queue)
        }
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.onClosed = onClosed
        self.handle = handle
    }

    /// Opens the door; returns the port it listens on.
    public func start() async throws -> UInt16 {
        let first = Once()
        let onClosed = self.onClosed
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: first.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case let .failed(error), let .waiting(error):
                    if !first.run({ continuation.resume(throwing: error) }) {
                        onClosed?(error)
                    }
                    listener.cancel()
                case .cancelled: first.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.read(connection, Data())
            case .failed, .waiting: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        // Longer than the 25-second wait for a join plus reply drain, shorter than for ever.
        queue.asyncAfter(deadline: .now() + 90) { connection.cancel() }
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = received
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .incomplete:
                if complete || error != nil { return connection.cancel() }
                self.read(connection, buffer)
            case let .malformed(words):
                self.send(.refused(400, words), on: connection, peerHalfClosed: complete)
            case let .complete(method, path, query, headers, body):
                let request = DoorRequest(method: method, path: path, query: query, headers: headers, body: body,
                    peerSPKI: Self.peerSPKI(connection))
                let handle = self.handle
                Task {
                    let reply = await handle(request)
                    self.send(reply, on: connection, peerHalfClosed: complete)
                }
            }
        }
    }

    enum Parsed: Equatable {
        case incomplete
        case malformed(String)
        case complete(method: String, path: String, query: [String: String], headers: [String: String], body: Data)
    }

    static func parse(_ buffer: Data) -> Parsed {
        let buffer = buffer.startIndex == 0 ? buffer : Data(buffer)
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > largestHead ? .malformed("The request's headers are too long.") : .incomplete
        }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .malformed("The request's headers are not text.") }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .malformed("Only HTTP/1.1 is spoken here.") }
        var length = 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "transfer-encoding" { return .malformed("Send the body with Content-Length; chunked bodies are not read here.") }
            if name == "content-length" {
                guard let count = Int(value), count >= 0, count <= largestBody else { return .malformed("The body is too large, or its length is not a number.") }
                length = count
            }
        }
        guard buffer.count - end.upperBound >= length else { return .incomplete }
        let target = URLComponents(string: String(parts[1]))
        let query = Dictionary((target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        return .complete(method: String(parts[0]), path: target?.path ?? String(parts[1]), query: query, headers: headers,
            body: Data(buffer[end.upperBound..<(end.upperBound + length)]))
    }

    private static func peerSPKI(_ connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let found = Found()
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if found.spki == nil { found.spki = try? RelayTLSIdentity.spki(certificate: sec_certificate_copy_ref(certificate).takeRetainedValue()) }
        }
        return found.spki
    }

    private final class Found: @unchecked Sendable { var spki: Data? }

    private func send(_ reply: DoorReply, on connection: NWConnection, peerHalfClosed: Bool) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 503: "Service Unavailable"][reply.status] ?? "Error"
        let head = "HTTP/1.1 \(reply.status) \(reason)\r\n"
            + "Content-Type: \(reply.isText ? "text/plain; charset=utf-8" : "application/x-protobuf")\r\n"
            + "Content-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n"
        // Send with .finalMessage so TLS sends close_notify and TCP sends FIN after the reply drains.
        // Never call connection.cancel() directly inside .contentProcessed, which fires before the
        // kernel send buffer drains over Tailscale and aborts large replies (such as /v2/bundle) with TCP RST.
        connection.send(content: Data(head.utf8) + reply.body, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { return connection.cancel() }
                if peerHalfClosed {
                    self.queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
                } else {
                    self.waitForClose(connection)
                }
            })
    }

    /// Waits for the peer to finish reading and close its side after `.finalMessage`, then releases the socket.
    private func waitForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            if complete || error != nil {
                connection.cancel()
            } else {
                self?.waitForClose(connection)
            }
        }
    }
}

/// Runs its closure the first time only, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    @discardableResult
    func run(_ action: () -> Void) -> Bool {
        let first = lock.withLock { if done { return false }; done = true; return true }
        if first { action() }
        return first
    }
}

/// This computer's Tailscale address, read from its interfaces each time: 100.64.0.0/10 first, else fd7a:115c:a1e0::/48.
extension Tailnet {
    public static func address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var six: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socket = entry.pointee.ifa_addr else { continue }
            if socket.pointee.sa_family == UInt8(AF_INET) {
                let address = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if address & 0xFFC0_0000 == 0x6440_0000 {
                    return "\(address >> 24).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
                }
            } else if socket.pointee.sa_family == UInt8(AF_INET6), six == nil {
                var raw = socket.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: &raw) { Array($0) }
                if bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) {
                    var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &raw, &text, socklen_t(text.count))
                    six = String(cString: text)
                }
            }
        }
        return six
    }

    /// "host:port", with an IPv6 address in brackets.
    public static func join(_ host: String, _ port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
