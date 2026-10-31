import AgentKeyringProtocol
import Foundation
import Network
import OSLog
import Security
import SwiftProtobuf

public struct RelayEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16, allowsLoopbackForProof: Bool = false) throws {
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = segments.compactMap { UInt8($0) }
        let tailnetV4 = segments.count == 4 && parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
        let tailnetV6 = host.lowercased().hasPrefix("fd7a:115c:a1e0:")
        let tailnetDNS = host.lowercased().hasSuffix(".ts.net") && !host.contains("/")
        guard port > 0, tailnetV4 || tailnetV6 || tailnetDNS || (allowsLoopbackForProof && host == "127.0.0.1") else {
            throw LeaseFailure(.invalidArgument, "Use the relay's Tailscale address and port.")
        }
        self.host = host
        self.port = port
    }
}

/// One framed method per TLS 1.3 connection, authenticated by the exact SPKI.
/// An absent pin is allowed only by the explicit first-pairing caller.
final class RelayConnection: @unchecked Sendable {
    private var connection: NWConnection!
    private let queue = DispatchQueue(label: "com.agentkeyring.relay-connection")
    private let lock = NSLock()
    private var observedSPKI: Data?
    private var opened = false
    var peerSPKI: Data { lock.withLock { observedSPKI ?? Data() } }

    init(endpoint: RelayEndpoint, identity: RelayTLSIdentity, pin: Data?) {
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

    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let finish: @Sendable (Error?) -> Void = { error in
                    let first = self.lock.withLock { if self.opened { return false }; self.opened = true; return true }
                    guard first else { return }
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(nil)
                    case let .failed(error): finish(error)
                    case let .waiting(error): finish(error); self.cancel()
                    case .cancelled: finish(CancellationError())
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) {
                    let stillOpening = self.lock.withLock { !self.opened }
                    if stillOpening {
                        finish(LeaseFailure(.unavailable, "The relay could not be reached."))
                        self.cancel()
                    }
                }
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
    }

    func send(_ request: Agentkeyring_V1_RelayWireRequest) async throws {
        let data = try request.serializedData()
        guard !data.isEmpty, data.count <= 1_048_576 else { throw LeaseFailure(.invalidArgument, "The relay request is too large.") }
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

    func next() async throws -> Agentkeyring_V1_RelayWireResponse {
        let header = try await read(4)
        let size = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard size > 0, size <= 1_048_576 else { throw LeaseFailure(.invalidArgument, "The relay sent an invalid frame.") }
        let response = try await Agentkeyring_V1_RelayWireResponse(serializedBytes: read(Int(size)))
        if case let .error(error) = response.response { throw LeaseFailure(error.code, error.message) }
        return response
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
                        else { continuation.resume(throwing: LeaseFailure(.unavailable, "The relay connection ended.")) }
                    }
                }
            } onCancel: { self.cancel() }
            result.append(bytes)
        }
        return result
    }
    func cancel() { connection.cancel() }
    deinit { connection.cancel() }
}

struct RelayTransport: Sendable {
    let endpoint: RelayEndpoint
    let identity: RelayTLSIdentity
    let pin: Data?

    func open(_ request: Agentkeyring_V1_RelayWireRequest) async throws -> RelayConnection {
        let connection = RelayConnection(endpoint: endpoint, identity: identity, pin: pin)
        do {
            try await connection.open()
            try await connection.send(request)
            return connection
        } catch { connection.cancel(); throw error }
    }

    func call(_ request: Agentkeyring_V1_RelayWireRequest) async throws -> Agentkeyring_V1_RelayWireResponse {
        let connection = try await open(request)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: Agentkeyring_V1_RelayWireResponse.self) { tasks in
            tasks.addTask { try await connection.next() }
            tasks.addTask { try await Task.sleep(for: .seconds(15)); throw LeaseFailure(.unavailable, "The relay did not acknowledge the request.") }
            defer { tasks.cancelAll(); connection.cancel() }
            return try await tasks.next()!
        }
    }
}
