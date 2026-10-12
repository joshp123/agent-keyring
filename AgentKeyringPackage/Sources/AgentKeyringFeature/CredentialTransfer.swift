import AppKit
import Foundation

public enum CredentialTransferError: Error, Sendable {
    case unavailable
}

/// Transfers one value across the app sandbox without changing the general clipboard.
@MainActor
public enum CredentialTransfer {
    private static let credentialType = NSPasteboard.PasteboardType("com.agentkeyring.credential")

    private static let codeType = NSPasteboard.PasteboardType("com.agentkeyring.totp")

    static func publishCode(_ record: MirrorCredential, requestID: UUID) throws {
        let channel = pasteboard(for: requestID)
        channel.clearContents()
        guard channel.setData(try PropertyListEncoder().encode(record), forType: codeType) else {
            channel.releaseGlobally()
            throw CredentialTransferError.unavailable
        }
    }

    private static func pasteboard(for requestID: UUID) -> NSPasteboard {
        NSPasteboard(name: .init("com.agentkeyring.credential.\(requestID.uuidString)"))
    }

    public static func publish(_ value: String, requestID: UUID) throws {
        let channel = pasteboard(for: requestID)
        channel.clearContents()
        guard channel.setData(Data(value.utf8), forType: credentialType) else {
            channel.releaseGlobally()
            throw CredentialTransferError.unavailable
        }
    }

    public static func read(requestID: UUID, now: Date = Date()) throws -> Data {
        let channel = pasteboard(for: requestID)
        if let data = channel.data(forType: codeType) {
            guard case let .totp(secret, period, digits, _, algorithm, _) =
                try PropertyListDecoder().decode(MirrorCredential.self, from: data) else {
                throw CredentialTransferError.unavailable
            }
            return Data(try TOTPGenerator().code(secret: secret, period: period,
                digits: digits, algorithm: algorithm, at: now).utf8)
        }
        guard let bytes = channel.data(forType: credentialType) else {
            throw CredentialTransferError.unavailable
        }
        return bytes
    }

    @discardableResult
    public static func clear(requestID: UUID) -> Bool {
        let channel = pasteboard(for: requestID)
        guard channel.clearContents() > 0 else { return false }
        channel.releaseGlobally()
        return true
    }
}

public struct AgentBridgeClient: Sendable {
    public let bridge: AgentBridgeDirectory

    public init(bridge: AgentBridgeDirectory = AgentBridgeDirectory()) {
        self.bridge = bridge
    }

    public func send(
        _ request: AgentBridgeRequest,
        launch: @Sendable (UUID) throws -> Void
    ) async throws -> AgentBridgeResponse {
        bridge.removeResponse(id: request.id)
        try bridge.write(request)
        defer {
            bridge.removeRequest(id: request.id)
            bridge.removeResponse(id: request.id)
        }
        try launch(request.id)
        let deadline = request.createdAt.addingTimeInterval(120)
        while Date() < deadline {
            if bridge.responseExists(id: request.id) {
                let response = try bridge.readResponse(id: request.id)
                guard response.id == request.id, response.version == request.version else {
                    throw AgentBridgeFailure(.invalidRequest, "The app returned an invalid receipt.")
                }
                return response
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AgentBridgeFailure(.timedOut, "The app did not respond before the request expired.")
    }
}
