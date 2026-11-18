// Written by AI on 2026.11.18 by model claude opus 5.5, from the iPhone
// engineer's copy in AgentKeyringPhoneApprover, so the Mac and iPhone share one.
//
// The relay's version 2 methods: one method per pinned TLS connection, framed
// protobuf (proto/agentkeyring/v2/keyring.proto).

import AgentKeyringProtocol
import Foundation

public struct KeyringRelay: Sendable {
    public let endpoint: RelayEndpoint
    public let identity: RelayTLSIdentity
    /// The relay's exact TLS key. With none, `call` reports the key it saw.
    public let pin: Data?

    public init(endpoint: RelayEndpoint, identity: RelayTLSIdentity, pin: Data?) {
        self.endpoint = endpoint
        self.identity = identity
        self.pin = pin
    }

    nonisolated(nonsending) private func open(_ request: Agentkeyring_V2_RelayRequest, observed: ((Data) -> Void)?) async throws -> RelayConnection {
        let connection = RelayConnection(endpoint: endpoint, identity: identity, pin: pin)
        do {
            try await connection.open()
            observed?(connection.peerSPKI)
            try await connection.sendFrame(request)
            return connection
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// One answer to one method.
    nonisolated(nonsending) public func call(_ request: Agentkeyring_V2_RelayRequest, observed: ((Data) -> Void)? = nil) async throws -> Agentkeyring_V2_RelayResponse {
        let connection = try await open(request, observed: observed)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: Agentkeyring_V2_RelayResponse.self) { tasks in
            tasks.addTask { try await Self.next(connection) }
            tasks.addTask {
                try await Task.sleep(for: .seconds(15))
                throw RelayFailure(.unavailable, "The relay did not answer.")
            }
            defer { tasks.cancelAll() }
            return try await tasks.next()!
        }
    }

    /// Every response of a streaming method, until the relay ends it or the task is cancelled.
    nonisolated(nonsending) public func stream(_ request: Agentkeyring_V2_RelayRequest, receive: (Agentkeyring_V2_RelayResponse) async throws -> Void) async throws {
        let connection = try await open(request, observed: nil)
        defer { connection.cancel() }
        while true {
            let response = try await Self.next(connection)
            try await receive(response)
            if response.endOfStream { return }
        }
    }

    private static func next(_ connection: RelayConnection) async throws -> Agentkeyring_V2_RelayResponse {
        let response: Agentkeyring_V2_RelayResponse = try await connection.nextFrame()
        if case let .error(error) = response.result { throw RelayFailure(.unavailable, error.message) }
        return response
    }
}
