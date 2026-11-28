import AgentKeyringProtocol
import Foundation

public struct AgentRPCError: Error, LocalizedError, Sendable {
    public let code: Agentkeyring_V2_RpcErrorCode
    public let message: String
    public init(_ code: Agentkeyring_V2_RpcErrorCode, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
