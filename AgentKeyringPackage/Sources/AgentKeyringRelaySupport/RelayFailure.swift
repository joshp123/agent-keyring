import AgentKeyringProtocol
import Foundation

public struct RelayFailure: Error, LocalizedError, Sendable {
    public let code: Agentkeyring_V1_RpcErrorCode
    public let message: String
    public init(_ code: Agentkeyring_V1_RpcErrorCode, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

struct RelayKeychainError: Error { let status: Int32 }
