import AppKit
import Foundation

public enum CredentialTransferError: Error, Sendable {
    case unavailable
}

/// Transfers one value across the app sandbox without changing the general clipboard.
@MainActor
public enum CredentialTransfer {
    private static let credentialType = NSPasteboard.PasteboardType("com.agentkeyring.credential")

    private struct BufferLifetime: Codable {
        let expiresAt: Date
    }
    private struct RetainedLifetime {
        let buffer: BufferLifetime
        let credentialID: UUID
        let codeRecord: MirrorCredential?
        var periodCounter: UInt64?
    }
    private static let lifetimeType = NSPasteboard.PasteboardType("com.agentkeyring.lifetime")
    private static var retainedLifetimes: [UUID: RetainedLifetime] = [:]
    private static var cleanupTask: Task<Void, Never>?

    private static func pasteboard(for requestID: UUID) -> NSPasteboard {
        NSPasteboard(name: .init("com.agentkeyring.credential.\(requestID.uuidString)"))
    }

    public static func publish(_ value: String, requestID: UUID,
        credentialID: UUID,
        expiresAfter: TimeInterval, codeRecord: MirrorCredential? = nil) throws {
        let publishedAt = Date()
        let publishedValue: String
        if case let .totp(seed, period, digits, _, algorithm, _) = codeRecord {
            publishedValue = try TOTPGenerator().code(secret: seed, period: period,
                digits: digits, algorithm: algorithm, at: publishedAt)
        } else {
            publishedValue = value
        }
        let channel = pasteboard(for: requestID)
        channel.clearContents()
        guard channel.setData(Data(publishedValue.utf8), forType: credentialType) else {
            channel.releaseGlobally()
            throw CredentialTransferError.unavailable
        }
        try retain(requestID: requestID,
            credentialID: credentialID, expiresAfter: expiresAfter, codeRecord: codeRecord,
            publishedAt: publishedAt)
    }

    public static func read(requestID: UUID, now: Date = Date()) throws -> Data {
        let channel = pasteboard(for: requestID)
        guard let lifetimeData = channel.data(forType: lifetimeType),
            let lifetime = try? PropertyListDecoder().decode(BufferLifetime.self, from: lifetimeData),
            isLive(lifetime, now: now) else {
            clear(requestID: requestID)
            throw CredentialTransferError.unavailable
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
        let references = retainedLifetimes.filter { !isLive($0.value.buffer, now: now) }.map(\.key)
        for reference in references { clear(requestID: reference) }
    }

    static func refreshRetainedValues(now: Date = Date()) {
        clearExpired(now: now)
        for (reference, lifetime) in retainedLifetimes {
            guard case let .totp(seed, period, digits, _, algorithm, _) = lifetime.codeRecord else {
                continue
            }
            let counter = UInt64(now.timeIntervalSince1970 / Double(period))
            guard counter != lifetime.periodCounter else { continue }
            do {
                let code = try TOTPGenerator().code(secret: seed, period: period,
                    digits: digits, algorithm: algorithm, at: now)
                guard pasteboard(for: reference).setData(Data(code.utf8), forType: credentialType) else {
                    throw CredentialTransferError.unavailable
                }
                retainedLifetimes[reference]?.periodCounter = counter
            } catch {
                clear(requestID: reference)
            }
        }
    }

    private static func isLive(_ lifetime: BufferLifetime, now: Date) -> Bool {
        lifetime.expiresAt > now
    }

    private static func retain(requestID: UUID,
        credentialID: UUID, expiresAfter: TimeInterval, codeRecord: MirrorCredential?,
        publishedAt: Date) throws {
        let lifetime = BufferLifetime(expiresAt: publishedAt.addingTimeInterval(expiresAfter))
        let channel = pasteboard(for: requestID)
        guard channel.setData(try PropertyListEncoder().encode(lifetime), forType: lifetimeType) else {
            clear(requestID: requestID)
            throw CredentialTransferError.unavailable
        }
        let counter: UInt64?
        if case let .totp(_, period, _, _, _, _) = codeRecord {
            counter = UInt64(publishedAt.timeIntervalSince1970 / Double(period))
        } else {
            counter = nil
        }
        retainedLifetimes[requestID] = RetainedLifetime(buffer: lifetime, credentialID: credentialID,
            codeRecord: codeRecord, periodCounter: counter)
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor in
            while !retainedLifetimes.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                refreshRetainedValues()
            }
            cleanupTask = nil
        }
    }

}

