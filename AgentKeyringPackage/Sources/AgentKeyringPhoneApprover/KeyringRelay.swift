// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The relay's version 2 methods, as the iPhone calls them: one method per
// pinned TLS connection, framed protobuf (proto/agentkeyring/v2/keyring.proto).

import AgentKeyringProtocol
import AgentKeyringRelaySupport
import CryptoKit
import Foundation

public typealias RelayRequest = Agentkeyring_V2_RelayRequest
public typealias RelayResponse = Agentkeyring_V2_RelayResponse

public struct KeyringRelayError: Error, Equatable {
    public let code: Agentkeyring_V2_ErrorCode
    public let message: String
}

struct KeyringRelay: Sendable {
    let endpoint: RelayEndpoint
    let identity: RelayTLSIdentity
    /// The relay's exact TLS key, from the signed Members; or, before joining,
    /// only its SHA-256 from the code scanned on the Mac.
    let pin: Data?
    var pinSHA256: Data? = nil

    func open(_ request: RelayRequest) async throws -> RelayConnection {
        let connection = RelayConnection(endpoint: endpoint, identity: identity, pin: pin)
        do {
            try await connection.open()
            if let pinSHA256, Data(SHA256.hash(data: connection.peerSPKI)) != pinSHA256 {
                throw KeyringRelayError(code: .notAllowed, message: "This is not the relay your Mac showed.")
            }
            try await connection.sendFrame(request)
            return connection
        } catch { connection.cancel(); throw error }
    }

    /// One answer to one method.
    func call(_ request: RelayRequest) async throws -> RelayResponse {
        let connection = try await open(request)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: RelayResponse.self) { tasks in
            tasks.addTask { try await Self.next(connection) }
            tasks.addTask {
                try await Task.sleep(for: .seconds(15))
                throw KeyringRelayError(code: .unavailable, message: "The relay did not answer.")
            }
            defer { tasks.cancelAll() }
            return try await tasks.next()!
        }
    }

    /// Every frame of a streaming method, until the relay ends it or the task is cancelled.
    func stream(_ request: RelayRequest) -> AsyncThrowingStream<RelayResponse, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let connection = try await open(request)
                    defer { connection.cancel() }
                    while !Task.isCancelled {
                        let response = try await Self.next(connection)
                        continuation.yield(response)
                        if response.endOfStream { break }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func next(_ connection: RelayConnection) async throws -> RelayResponse {
        let response: RelayResponse = try await connection.nextFrame()
        if case let .error(error) = response.result { throw KeyringRelayError(code: error.code, message: error.message) }
        return response
    }
}
