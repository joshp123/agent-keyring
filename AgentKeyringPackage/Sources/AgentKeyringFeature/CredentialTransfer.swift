import AppKit
import Darwin
import Foundation

public enum CredentialTransferError: Error, Sendable {
    case unavailable
}

/// Transfers one value across the app sandbox without changing the general clipboard.
@MainActor
public enum CredentialTransfer {
    private static let credentialType = NSPasteboard.PasteboardType("com.agentkeyring.credential")

    private static let codeType = NSPasteboard.PasteboardType("com.agentkeyring.totp")

    private struct RetainedLifetime: Codable {
        let expiresAt: Date
        let requesterPID: Int32
        let credentialID: UUID?
    }
    private static let lifetimeType = NSPasteboard.PasteboardType("com.agentkeyring.lifetime")
    private static var retainedLifetimes: [UUID: RetainedLifetime] = [:]
    private static var cleanupTask: Task<Void, Never>?

    static func publishCode(_ record: MirrorCredential, requestID: UUID,
        requesterPID: Int32 = getpid(), credentialID: UUID? = nil,
        expiresAfter: TimeInterval = 300) throws {
        let channel = pasteboard(for: requestID)
        channel.clearContents()
        guard channel.setData(try PropertyListEncoder().encode(record), forType: codeType) else {
            channel.releaseGlobally()
            throw CredentialTransferError.unavailable
        }
        try retain(requestID: requestID, requesterPID: requesterPID,
            credentialID: credentialID, expiresAfter: expiresAfter)
    }

    private static func pasteboard(for requestID: UUID) -> NSPasteboard {
        NSPasteboard(name: .init("com.agentkeyring.credential.\(requestID.uuidString)"))
    }

    public static func publish(_ value: String, requestID: UUID,
        requesterPID: Int32 = getpid(), credentialID: UUID? = nil,
        expiresAfter: TimeInterval = 300) throws {
        let channel = pasteboard(for: requestID)
        channel.clearContents()
        guard channel.setData(Data(value.utf8), forType: credentialType) else {
            channel.releaseGlobally()
            throw CredentialTransferError.unavailable
        }
        try retain(requestID: requestID, requesterPID: requesterPID,
            credentialID: credentialID, expiresAfter: expiresAfter)
    }

    public static func read(requestID: UUID, now: Date = Date()) throws -> Data {
        let channel = pasteboard(for: requestID)
        guard let lifetimeData = channel.data(forType: lifetimeType),
            let lifetime = try? PropertyListDecoder().decode(RetainedLifetime.self, from: lifetimeData),
            isLive(lifetime, now: now) else {
            clear(requestID: requestID)
            throw CredentialTransferError.unavailable
        }
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
        retainedLifetimes.removeValue(forKey: requestID)
        let channel = pasteboard(for: requestID)
        guard channel.clearContents() > 0 else { return false }
        channel.releaseGlobally()
        return true
    }
    static func revoke(credentialID: UUID) {
        let references = retainedLifetimes.filter { $0.value.credentialID == credentialID }.map(\.key)
        for reference in references { clear(requestID: reference) }
    }

    static func clearExpired(now: Date = Date()) {
        let references = retainedLifetimes.filter { !isLive($0.value, now: now) }.map(\.key)
        for reference in references { clear(requestID: reference) }
    }

    private static func isLive(_ lifetime: RetainedLifetime, now: Date) -> Bool {
        lifetime.expiresAt > now && lifetime.requesterPID > 0
            && (kill(lifetime.requesterPID, 0) == 0 || errno == EPERM)
    }

    private static func retain(requestID: UUID, requesterPID: Int32,
        credentialID: UUID?, expiresAfter: TimeInterval) throws {
        let lifetime = RetainedLifetime(expiresAt: Date().addingTimeInterval(expiresAfter),
            requesterPID: requesterPID, credentialID: credentialID)
        let channel = pasteboard(for: requestID)
        guard channel.setData(try PropertyListEncoder().encode(lifetime), forType: lifetimeType) else {
            clear(requestID: requestID)
            throw CredentialTransferError.unavailable
        }
        retainedLifetimes[requestID] = lifetime
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor in
            while !retainedLifetimes.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                clearExpired()
            }
            cleanupTask = nil
        }
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
