import Darwin
import Foundation

/// Kernel-supplied identity of the process that connected, independent of request contents.
public struct AgentBridgePeer: Sendable {
    public let processIdentifier: pid_t
    public let auditToken: Data

    fileprivate init(socket: Int32) throws {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0,
            getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0,
            pidSize == MemoryLayout<pid_t>.size, tokenSize == MemoryLayout<audit_token_t>.size,
            pid > 0 else { throw socketFailure() }
        processIdentifier = pid
        auditToken = withUnsafeBytes(of: &token) { Data($0) }
    }
}

private func socketFailure() -> AgentBridgeFailure {
    AgentBridgeFailure(.bridgeUnavailable, "Agent Keyring's socket connection failed (\(errno)).")
}

private func withSocketAddress<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    let path = Array(url.path.utf8) + [0]
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw AgentBridgeFailure(.bridgeUnavailable, "The Agent Keyring socket path is too long.")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private enum AgentSocketEvent: Codable, Sendable {
    case progress(AgentApprovalProgress)
    case response(AgentBridgeResponse)
}

/// A blocking reader runs on a Dispatch worker; the app's main actor never waits on socket I/O.
private final class AgentSocketConnection: @unchecked Sendable {
    let descriptor: Int32
    private let writeLock = NSLock()
    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { Darwin.close(descriptor) }
    func disconnect() { shutdown(descriptor, SHUT_RDWR) }

    func send<Value: Encodable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw AgentBridgeFailure(.invalidRequest, "The socket message is too large.") }
        var length = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        writeLock.lock()
        defer { writeLock.unlock() }
        try write(header + data)
    }

    func receive<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let header = try read(count: 4)
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= 1_048_576 else { throw AgentBridgeFailure(.invalidRequest, "Invalid socket message length.") }
        return try JSONDecoder().decode(type, from: read(count: Int(length)))
    }

    private func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw socketFailure() }
                offset += received
            }
        }
        return data
    }
    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw socketFailure() }
                offset += sent
            }
        }
    }

    static func connect(to url: URL) throws -> AgentSocketConnection {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketFailure() }
        let connection = AgentSocketConnection(descriptor)
        try withSocketAddress(url) { address, length in
            guard Darwin.connect(descriptor, address, length) == 0 else { throw socketFailure() }
        }
        return connection
    }
}

public final class AgentBridgeServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (AgentBridgeRequest, AgentBridgePeer,
        @escaping (AgentApprovalProgress) -> Void) async throws -> AgentBridgeResponse
    private let source: DispatchSourceRead
    private let socketURL: URL

    public init(bridge: AgentBridgeDirectory = AgentBridgeDirectory(), handler: @escaping Handler) throws {
        try bridge.prepare()
        socketURL = bridge.socketURL
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketFailure() }
        do {
            // A running listener owns the endpoint. Only remove a socket left by an exited app.
            if FileManager.default.fileExists(atPath: socketURL.path) {
                if let existing = try? AgentSocketConnection.connect(to: socketURL) {
                    existing.disconnect()
                    throw AgentBridgeFailure(.bridgeUnavailable, "Agent Keyring already has an agent listener.")
                }
                guard unlink(socketURL.path) == 0 else { throw socketFailure() }
            }
            try withSocketAddress(socketURL) { address, length in
                guard bind(descriptor, address, length) == 0 else { throw socketFailure() }
            }
            guard chmod(socketURL.path, 0o600) == 0, listen(descriptor, 16) == 0,
                fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw socketFailure() }
        } catch { Darwin.close(descriptor); throw error }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler {
            while true {
                let accepted = accept(descriptor, nil, nil)
                guard accepted >= 0 else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let connection = AgentSocketConnection(accepted)
                    do {
                        let peer = try AgentBridgePeer(socket: accepted)
                        // Limit an incomplete initial request to the request lifetime.
                        var timeout = timeval(tv_sec: 600, tv_usec: 0)
                        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                        let request = try connection.receive(AgentBridgeRequest.self)
                        Task { @MainActor in
                            do {
                                let response = try await handler(request, peer) { progress in
                                    try? connection.send(AgentSocketEvent.progress(progress))
                                }
                                try connection.send(AgentSocketEvent.response(response))
                            } catch { /* A CLI may stop waiting while the app finishes approval. */ }
                            connection.disconnect()
                        }
                    } catch { connection.disconnect() }
                }
            }
        }
        source.resume()
    }
    deinit {
        source.cancel()
        unlink(socketURL.path)
    }
}

public struct AgentBridgeClient: Sendable {
    public let bridge: AgentBridgeDirectory
    public init(bridge: AgentBridgeDirectory = AgentBridgeDirectory()) { self.bridge = bridge }

    @MainActor
    public func send(_ request: AgentBridgeRequest, waitUntil: Date? = nil,
        onStatus: (AgentBridgeWaitStatus) -> Void = { _ in },
        launch: @Sendable (UUID) async throws -> Void) async throws -> AgentBridgeResponse {
        let deadline = min(request.expiresAt, waitUntil ?? request.expiresAt)
        var connection = try? AgentSocketConnection.connect(to: bridge.socketURL)
        if connection == nil {
            try await launch(request.id)
            // Startup only: replies and progress are delivered by the socket, never polled.
            let startupDeadline = min(deadline, Date().addingTimeInterval(10))
            while connection == nil, Date() < startupDeadline {
                try Task.checkCancellation()
                connection = try? AgentSocketConnection.connect(to: bridge.socketURL)
                if connection == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
        }
        guard let connection else { throw socketFailure() }
        defer { connection.disconnect() }
        try connection.send(request)
        enum Event: Sendable { case message(AgentSocketEvent), failed, tick, deadline }
        let (events, continuation) = AsyncStream<Event>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                while true {
                    let message = try connection.receive(AgentSocketEvent.self)
                    continuation.yield(.message(message))
                    if case .response = message { break }
                }
            } catch { continuation.yield(.failed) }
        }
        let ticker = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    continuation.yield(.tick)
                }
            } catch { }
        }
        let expiry = Task {
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                continuation.yield(.deadline)
            } catch { }
        }
        defer { ticker.cancel(); expiry.cancel(); continuation.finish() }
        var lastProgress: AgentApprovalProgress?
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case let .message(.progress(progress)):
                if progress != lastProgress { onStatus(.progress(progress)); lastProgress = progress }
            case let .message(.response(response)):
                guard response.id == request.id, response.version == request.version else {
                    throw AgentBridgeFailure(.invalidRequest, "The app returned an invalid receipt.")
                }
                return response
            case .tick:
                if let lastProgress { onStatus(.stillWaiting(progress: lastProgress)) }
            case .failed: throw socketFailure()
            case .deadline:
                if Date() >= request.expiresAt { throw AgentBridgeFailure(.requestExpired, "The request expired with no answer.") }
                return AgentBridgeResponse(id: request.id, ok: false, error: .approvalPending,
                    approvalProgress: lastProgress ?? AgentApprovalProgress(waitingSince: request.createdAt, phase: .awaitingApproval))
            }
        }
        throw CancellationError()
    }
}
