// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// The Mac's door, as the iPhone uses it: HTTPS to the Mac's Tailscale IP,
// pinned to the Mac's key, with this iPhone's TLS client certificate.

import AgentKeyringSealing
import Foundation
import Security

struct PhoneMacDoor: @unchecked Sendable {
    let host: String
    let port: UInt16
    let key: Data
    let client: SecIdentity

    enum Failure: Error, CustomStringConvertible {
        case notJoined
        case notAllowed(String)
        /// The Mac refused it. Its members' door asks for a client certificate, so URLSession reports the
        /// Mac's 403 as "requires a client certificate" (-1206), never with the Mac's own sentence.
        case refusedByMac
        var description: String {
            switch self {
            case .notJoined: "this iPhone has not joined a Mac"
            case let .notAllowed(words): words
            case .refusedByMac: "the Mac refused it"
            }
        }
    }

    func post(_ path: String, _ body: Data, query: [URLQueryItem] = [], timeout: TimeInterval = 15) async throws -> Data {
        try await refusals { try await DoorHTTPS.send("POST", body, host: host, port: port, path: path, query: query, pinned: key, client: client, timeout: timeout) }
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await refusals { try await DoorHTTPS.send("GET", host: host, port: port, path: path, query: query, pinned: key, client: client) }
    }

    private func refusals(_ call: () async throws -> Data) async throws -> Data {
        do { return try await call() } catch let error as URLError where error.code == .clientCertificateRequired {
            throw Failure.refusedByMac
        } catch let failure as DoorHTTPS.Failure where failure.status == 403 {
            throw Failure.refusedByMac
        }
    }
}
