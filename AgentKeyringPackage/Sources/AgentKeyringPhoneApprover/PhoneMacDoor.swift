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
        var description: String {
            switch self {
            case .notJoined: "this iPhone has not joined a Mac"
            case let .notAllowed(words): words
            }
        }
    }

    func post(_ path: String, _ body: Data, timeout: TimeInterval = 15) async throws -> Data {
        try await DoorHTTPS.send("POST", body, host: host, port: port, path: path, pinned: key, client: client, timeout: timeout)
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await DoorHTTPS.send("GET", host: host, port: port, path: path, query: query, pinned: key, client: client)
    }
}
