import AgentKeyringApprovalCore
import AgentKeyringProtocol
import Foundation
import Network
import OSLog
import Security
import SwiftProtobuf

public struct RelayEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) throws {
        guard port > 0, !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.utf8.contains(0),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw RelayFailure(.invalidArgument, MessageCopy.notATailscaleAddress)
        }
        self.host = host
        self.port = port
    }

    public func permitsResolvedEndpoint(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address): return permitsIPv4(address)
        case let .ipv6(address):
            if address.isIPv4Mapped, let ipv4 = address.asIPv4 { return permitsIPv4(ipv4) }
            return address.rawValue.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        case .name: return false
        @unknown default: return false
        }
    }

    private func permitsIPv4(_ address: IPv4Address) -> Bool {
        let bytes = address.rawValue
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }
}

/// One framed method per TLS 1.3 connection, authenticated by the exact SPKI.
/// An absent pin is allowed only by the explicit first-pairing caller.
public final class RelayConnection: @unchecked Sendable {
    private var connection: NWConnection!
    private let queue = DispatchQueue(label: "com.agentkeyring.relay-connection")
    private let lock = NSLock()
    private var observedSPKI: Data?
    private var opened = false
    private let endpoint: RelayEndpoint
    public var peerSPKI: Data { lock.withLock { observedSPKI ?? Data() } }

    public init(endpoint: RelayEndpoint, identity: RelayTLSIdentity, pin: Data?) {
        self.endpoint = endpoint
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, suppliedTrust, complete in
            let trust = sec_trust_copy_ref(suppliedTrust).takeRetainedValue()
            guard let self, SecTrustGetCertificateCount(trust) == 1,
                let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate], certificate.count == 1,
                let spki = try? RelayTLSIdentity.spki(certificate: certificate[0]), pin == nil || pin == spki else {
                complete(false)
                return
            }
            SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(trust, certificate as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            guard SecTrustEvaluateWithError(trust, nil) else { complete(false); return }
            self.lock.withLock { self.observedSPKI = spki }
            complete(true)
        }, queue)
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!,
            using: NWParameters(tls: tls))
    }

    public func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Only the first outcome counts; later states of an open connection are for its reads.
                let finish: @Sendable (Error?) -> Bool = { error in
                    let first = self.lock.withLock { if self.opened { return false }; self.opened = true; return true }
                    guard first else { return false }
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    return true
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        do { try self.requireTailnetPeer(); _ = finish(nil) }
                        catch { _ = finish(error); self.cancel() }
                    case let .failed(error): _ = finish(error)
                    // While opening, no route means the relay is not there; once open, a
                    // network handoff passes through waiting and the connection carries on.
                    case let .waiting(error): if finish(error) { self.cancel() }
                    case .cancelled: _ = finish(CancellationError())
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) {
                    let stillOpening = self.lock.withLock { !self.opened }
                    if stillOpening, finish(RelayFailure(.unavailable, MessageCopy.unreachable)) {
                        self.cancel()
                    }
                }
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
    }

    /// One framed message.
    public func sendFrame(_ request: some SwiftProtobuf.Message) async throws {
        try requireTailnetPeer()
        let data = try request.serializedData()
        guard !data.isEmpty, data.count <= 4_194_304 else { throw RelayFailure(.invalidArgument, MessageCopy.messageTooLarge) }
        var size = UInt32(data.count).bigEndian
        let frame = withUnsafeBytes(of: &size) { Data($0) } + data
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { self.cancel() }
    }

    private func requireTailnetPeer() throws {
        guard endpoint.permitsResolvedEndpoint(connection.currentPath?.remoteEndpoint) else {
            connection.cancel()
            throw RelayFailure(.permissionDenied, MessageCopy.notOnTailscale)
        }
    }

    /// The next framed message. Frames are at most 4 MiB.
    public func nextFrame<Response: SwiftProtobuf.Message>() async throws -> Response {
        let header = try await read(4)
        let size = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard size > 0, size <= 4_194_304 else { throw RelayFailure(.invalidArgument, MessageCopy.unreadableReply) }
        return try await Response(serializedBytes: read(Int(size)))
    }

    private func read(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let bytes: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: RelayFailure(.unavailable, MessageCopy.connectionEnded)) }
                    }
                }
            } onCancel: { self.cancel() }
            result.append(bytes)
        }
        return result
    }
    public func cancel() { connection.cancel() }
    deinit { connection.cancel() }
}
