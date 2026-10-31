import AgentKeyringProtocol
import SwiftProtobuf
import Darwin
import Foundation
import OSLog

private let socketLogger = Logger(subsystem: "com.agentkeyring.app", category: "AgentSocket")

/// Kernel-supplied identity of the process that connected, independent of request contents.
public struct AgentBridgePeer: Sendable {
    public let processIdentifier: pid_t
    public let auditToken: Data
    public let userID: uid_t

    fileprivate init(socket: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid == getuid() else { throw socketFailure() }
        userID = uid
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

/// A blocking reader runs on a Dispatch worker; the app's main actor never waits on socket I/O.
private final class AgentSocketConnection: @unchecked Sendable {
    let descriptor: Int32
    private let writer = DispatchQueue(label: "com.agentkeyring.socket-writer")
    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    deinit { Darwin.close(descriptor) }
    func disconnect() { shutdown(descriptor, SHUT_RDWR) }

    func publish(_ response: Agentkeyring_V1_WireResponse) {
        writer.async {
            defer { if response.endOfStream { self.disconnect() } }
            do { try self.sendFrame(response.serializedData()) }
            catch { self.disconnect() }
        }
    }

    private func sendFrame(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw socketFailure() }
        var length = UInt32(data.count).bigEndian
        try write(withUnsafeBytes(of: &length) { Data($0) } + data)
    }

    func receiveRequest() throws -> Agentkeyring_V1_WireRequest? {
        let header = try read(count: 4)
        let length = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= 1_048_576 else { throw socketFailure() }
        let data = try read(count: Int(length))
        if data.first == UInt8(ascii: "{") {
            // One migration reply for the installed JSON client. No legacy action
            // is executed, including acquire/fill/status.
            let request = try? JSONDecoder().decode(AgentBridgeRequest.self, from: data)
            let response = AgentBridgeResponse(id: request?.id ?? UUID(), ok: false,
                error: .invalidRequest, message: "Agent Keyring now uses task leases. Use agent-keyring lease LOGIN --task TASK --reason REASON with the bundled CLI.")
            enum LegacyEvent: Encodable { case response(AgentBridgeResponse) }
            try sendFrame(JSONEncoder().encode(LegacyEvent.response(response)))
            disconnect()
            return nil
        }
        return try Agentkeyring_V1_WireRequest(serializedBytes: data)
    }

    func waitForDisconnect() {
        var byte: UInt8 = 0
        while Darwin.read(descriptor, &byte, 1) < 0 && errno == EINTR { }
        disconnect()
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
    public typealias Handler = @MainActor @Sendable (Agentkeyring_V1_WireRequest, AgentBridgePeer,
        @escaping @Sendable (Agentkeyring_V1_WireResponse) -> Void) async -> Void
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
                // Darwin inherits O_NONBLOCK from the listening socket.
                guard fcntl(accepted, F_SETFL, 0) == 0 else { Darwin.close(accepted); continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    let connection = AgentSocketConnection(accepted)
                    do {
                        let peer = try AgentBridgePeer(socket: accepted)
                        // Limit an incomplete initial request to the request lifetime.
                        var timeout = timeval(tv_sec: 600, tv_usec: 0)
                        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                        guard let request = try connection.receiveRequest() else { return }
                        // Watch is independent of the requesting process lifetime.
                        // Disconnect cancels only this observer, never its lease.
                        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
                        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
                        let handling = Task { @MainActor in
                            await handler(request, peer) { response in connection.publish(response) }
                        }
                        connection.waitForDisconnect()
                        handling.cancel()
                    } catch {
                        socketLogger.debug("Agent socket request unreadable: \(String(describing: error), privacy: .private)")
                        connection.disconnect()
                    }
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
