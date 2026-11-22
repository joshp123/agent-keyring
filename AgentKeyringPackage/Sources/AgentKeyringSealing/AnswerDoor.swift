// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// The asking computer's answer door: devices post their answers and arrival
// notes to the address its signed request names, pinned to its key in Members
// (Sealing.checkRequest has checked both). On a computer, the process that
// holds the door can change while a request waits, so an answer that cannot
// connect is not delivered yet: it is retried for `retryFor`, not failed at once.

import AgentKeyringProtocol
import Foundation

public enum AnswerDoor {
    /// How long an answer that cannot reach the door keeps trying.
    /// A variable only so a test need not wait the whole of it.
    nonisolated(unsafe) public static var retryFor: TimeInterval = 30
    static let retryEvery: TimeInterval = 2

    public typealias Door = (host: String, port: UInt16, key: Data)

    /// The door refused the answer, in its own words (an unknown device, a changed request).
    public struct Refused: Error, CustomStringConvertible {
        public let words: String
        public var description: String { words }
    }

    /// The door could not be reached for `retryFor`.
    public struct NotDelivered: Error, CustomStringConvertible {
        public let last: Error
        public var description: String { "not delivered: \(last)" }
    }

    /// Posts an answer and returns the request's Lease: this answer's, or the one that already ended
    /// the request (the first answer wins). `waiting` is called once if the first try cannot connect.
    public static func answer(_ upload: AnswerUpload, at door: Door,
                              waiting: @Sendable () -> Void = {}) async throws -> Agentkeyring_V2_Lease {
        let body = try upload.serializedData()
        let giveUp = Date().addingTimeInterval(retryFor)
        var told = false
        while true {
            do {
                let reply = try await DoorHTTPS.post(body, host: door.host, port: door.port, path: "/v2/answer", pinned: door.key)
                return try Agentkeyring_V2_Lease(serializedBytes: reply)
            } catch let failure as DoorHTTPS.Failure where failure.status == 403 {
                throw Refused(words: failure.words)
            } catch let failure as DoorHTTPS.Failure where failure.status != 0 {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if isPermanentTLSFailure(error) { throw NotDelivered(last: error) }
                guard Date() < giveUp else { throw NotDelivered(last: error) }
                if !told { told = true; waiting() }
                try await Task.sleep(for: .seconds(retryEvery))
            }
        }
    }

    /// Stop: posts a signed EndRequest and returns the request's Lease, retrying as an answer does.
    public static func end(_ request: SignedDocument, at door: Door) async throws -> Data {
        let body = try request.serializedData()
        let giveUp = Date().addingTimeInterval(retryFor)
        while true {
            do {
                return try await DoorHTTPS.post(body, host: door.host, port: door.port, path: "/v2/end", pinned: door.key)
            } catch let failure as DoorHTTPS.Failure where failure.status == 403 {
                throw Refused(words: failure.words)
            } catch let failure as DoorHTTPS.Failure where failure.status != 0 {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if isPermanentTLSFailure(error) { throw NotDelivered(last: error) }
                guard Date() < giveUp else { throw NotDelivered(last: error) }
                try await Task.sleep(for: .seconds(retryEvery))
            }
        }
    }

    /// Errors caused by App Transport Security, TLS handshake rejection, or a mismatched pinned key
    /// will not clear on retry, so fail immediately instead of blocking for `retryFor`.
    private static func isPermanentTLSFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorCancelled:
            return true
        case NSURLErrorSecureConnectionFailed:
            let sslCode = (nsError.userInfo["_kCFStreamErrorCodeKey"] as? Int)
                ?? ((nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.userInfo["_kCFStreamErrorCodeKey"] as? Int)
            return sslCode == -9802 // errSSLFatalAlert
        default:
            return false
        }
    }

    /// Posts an arrival note once, within `ArrivalNote.deadline`.
    public static func arrived(_ note: SignedDocument, at door: Door) async throws {
        _ = try await DoorHTTPS.post(note.serializedData(), host: door.host, port: door.port, path: "/v2/arrived",
                                      pinned: door.key, timeout: ArrivalNote.deadline)
    }
}
