// Written by AI on 2026.11.23 by model claude opus 5.5; GET, tokens, grants
// and update mailboxes on 2026.11.24.
//
// Boxes, which carry everything between a computer and Josh's devices
// (keyring.proto, "Boxes"; the command has the same in Go, internal/box): the join code
// and the keys it gives, sealing a message into one or more boxes, grants and
// Stop, update mailboxes, and the relay's /v1/box. The relay sees only random
// ids, tokens' hashes and ciphertext. Shared by the Mac, iPhone and Apple Watch.

import CryptoKit
import Foundation

/// How long a box lasts at the relay (x-akr-ttl).
public enum RelayBoxTTL: String, Sendable { case enrol, grant, update }
/// What a PUT does (x-akr-mode).
public enum RelayBoxPutMode: String, Sendable { case create, replace, stop }

public enum RelayBoxError: Error, Equatable, CustomStringConvertible {
    /// Someone answered first: the box already holds a message.
    case exists
    /// The relay refused this box's token, or a stop of a grant that is not there.
    case forbidden
    case unreadable
    case missingPart
    case tooLarge
    case refused(Int)
    /// The relay could not be reached: the URLError code, without its URL.
    case unreachable(Int)
    public var description: String {
        switch self {
        case .exists: "the box already holds a message"
        case .forbidden: "the relay refused this box's token"
        case .unreadable: "the box does not open with this key"
        case .missingPart: "a part of the message was not at the relay"
        case .tooLarge: "the message is too large for the relay"
        case let .refused(status): "the relay answered \(status)"
        case let .unreachable(code): "the relay could not be reached (\(code))"
        }
    }
    /// Worth trying again: unreachable, busy or failing.
    var retryable: Bool {
        switch self {
        case .unreachable: true
        case let .refused(status): status == 429 || status >= 500
        default: false
        }
    }
}

/// Where an approval answered in a box is marked live or stopped (keyring.proto, "Grants and Stop").
public struct LeaseGrantBox: Equatable, Sendable {
    public let id: String
    public let readAuth: String
    public let writeAuth: String

    public init(answerBox: String, key: Data) {
        id = RelayBoxProtocol.hex(Data(SHA256.hash(data: Data("agentkeyring.grant.v1\(answerBox)".utf8))))
        readAuth = RelayBoxProtocol.base64URL(RelayBoxProtocol.derive(key, "agentkeyring.grant.v1 read auth"))
        writeAuth = RelayBoxProtocol.base64URL(RelayBoxProtocol.derive(key, "agentkeyring.grant.v1 write auth"))
    }
}

public enum RelayBoxProtocol {
    public static let defaultURL = "https://push.opentrawl.sh"
    /// The most of a message one box holds, under the relay's 256 KiB.
    static let partSize = 196_608
    /// The most boxes one message may take, and the most one box holds.
    static let maxParts = 64
    static let maxBoxBytes = 256 * 1024

    /// How long a side waiting on a box waits before it looks again, having waited `waited` so far: half
    /// a second for the first 15 seconds, a second to a minute, then 3 seconds, each up to 10% either way.
    public static func pollInterval(waited: TimeInterval) -> Duration {
        let every = waited < 15 ? 0.5 : waited < 60 ? 1.0 : 3.0
        return .milliseconds(Int(every * Double.random(in: 0.9...1.1) * 1000))
    }

    /// 32 to 64 lowercase hex characters, as the relay takes.
    public static func isValidID(_ id: String) -> Bool {
        (32...64).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The box that holds part `index` > 0 of a message whose part nonce is `nonce`.
    public static func partID(nonce: Data, _ index: UInt32) -> String {
        hex(Data(SHA256.hash(data: Data("agentkeyring.box.part.v1\(hex(nonce))".utf8) + bigEndian(index))))
    }

    /// A fresh read or write token: 32 random bytes, base64url.
    static func newToken() -> String { base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }

    static func derive(_ secret: Data, _ info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(), info: Data(info.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The box a device writes a computer's updates in (keyring.proto, "Update mailboxes").
    public static func mailboxSlot(seed: Data, deviceKeyID: String) -> String {
        hex(derive(seed, "agentkeyring.mailbox.v1 slot \(deviceKeyID)"))
    }

    /// The key every slot of a mailbox is sealed with.
    public static func mailboxKey(seed: Data) -> Data { derive(seed, "agentkeyring.mailbox.v1 key") }

    /// Seals one chunk's plaintext for box `id`. `nonce` is fixed only by a test.
    public static func sealBoxChunk(_ plaintext: Data, box id: String, key: Data, nonce: Data? = nil) throws -> Data {
        guard key.count == 32, nonce == nil || nonce?.count == 12 else { throw RelayBoxError.unreadable }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                      nonce: nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce(),
                                      authenticating: Data("agentkeyring.box.v1\(id)".utf8))
        return sealed.combined!
    }

    public static func openBoxChunk(_ sealed: Data, box id: String, key: Data) throws -> Data {
        guard sealed.count >= 28, key.count == 32 else { throw RelayBoxError.unreadable }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: key),
                                    authenticating: Data("agentkeyring.box.v1\(id)".utf8))
        } catch { throw RelayBoxError.unreadable }
    }

    /// A message for box `id` cut into its chunks, chunk 0 first: each one's box and plaintext, the count of
    /// chunks first, and in chunk 0 the chunk nonce (16 bytes) after it.
    public static func splitIntoBoxChunks(_ message: Data, box id: String, nonce: Data) -> [(id: String, plaintext: Data)] {
        let count = max(1, (message.count + partSize - 1) / partSize)
        return (0..<count).map { index in
            let start = message.startIndex + index * partSize
            let chunk = message[start..<min(message.endIndex, start + partSize)]
            return index == 0 ? (id, bigEndian(UInt32(count)) + nonce + chunk)
                : (partID(nonce: nonce, UInt32(index)), bigEndian(UInt32(count)) + chunk)
        }
    }

    static func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

// MARK: Joining with a code

/// Everything the code gives both sides of a join.
public struct ComputerJoinCodeKeys: Equatable, Sendable {
    public let requestBox: String
    public let requestKey: Data
    public let responseBox: String
    public let responseKey: Data
    /// The secret for JoinRequest.proof and JoinRefusal, in place of JoinInvite.secret.
    public let proof: Data
}

public struct ComputerJoinCode: Equatable, Sendable {
    /// 16 random bytes.
    public let secret: Data
    /// The relay, if not the default.
    public let relay: String?

    public init(secret: Data, relay: String? = nil) {
        self.secret = secret
        self.relay = relay == RelayBoxProtocol.defaultURL ? nil : relay
    }

    /// A new one-time code.
    public static func make(relay: String? = nil) -> ComputerJoinCode {
        ComputerJoinCode(secret: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }, relay: relay)
    }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 26 characters in groups of four: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX.
    public var code: String {
        var bits: UInt64 = 0, have = 0
        var out: [Character] = []
        for byte in secret + [0] {
            bits = bits << 8 | UInt64(byte)
            have += 8
            while have >= 5, out.count < 26 {
                have -= 5
                out.append(Self.alphabet[Int((bits >> UInt64(have)) & 31)])
            }
        }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(separator: "-")
    }

    /// As a link or QR code, naming the relay if it is not the default.
    public var link: String {
        var link = "agentkeyring://join?code=" + code.replacingOccurrences(of: "-", with: "")
        if let relay { link += "&relay=" + (relay.addingPercentEncoding(withAllowedCharacters: Self.queryValue) ?? relay) }
        return link
    }

    /// What a person runs on the computer: the code alone, or the link when the relay is not the default.
    public var enrolArgument: String { relay == nil ? code : link }

    private static let queryValue: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// A code as a person typed it (any case, hyphens or spaces, I and L for 1, O for 0), or a link.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var codeText = trimmed, relay: String?
        if trimmed.hasPrefix("agentkeyring://join?") {
            let items = URLComponents(string: trimmed)?.queryItems ?? []
            guard let code = items.first(where: { $0.name == "code" })?.value else { return nil }
            codeText = code
            relay = items.first(where: { $0.name == "relay" })?.value
        }
        let cleaned = codeText.uppercased().filter { $0 != "-" && $0 != " " }
            .map { $0 == "I" || $0 == "L" ? "1" : $0 == "O" ? "0" : $0 }
        guard cleaned.count == 26 else { return nil }
        var bits: UInt64 = 0, have = 0
        var secret = Data()
        for character in cleaned {
            guard let value = Self.alphabet.firstIndex(of: character) else { return nil }
            bits = bits << 5 | UInt64(value)
            have += 5
            if have >= 8, secret.count < 16 {
                have -= 8
                secret.append(UInt8(truncatingIfNeeded: bits >> UInt64(have)))
            }
        }
        guard bits & 3 == 0 else { return nil }
        self.init(secret: secret, relay: relay)
    }

    public var keys: ComputerJoinCodeKeys {
        func part(_ info: String) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(),
                                   info: Data("agentkeyring.join.v1 \(info)".utf8), outputByteCount: 32)
                .withUnsafeBytes { Data($0) }
        }
        return ComputerJoinCodeKeys(requestBox: RelayBoxProtocol.hex(part("request box")), requestKey: part("request key"),
                    responseBox: RelayBoxProtocol.hex(part("response box")), responseKey: part("response key"), proof: part("proof"))
    }
}

// MARK: The relay

/// How a PUT keeps its box. The default lasts 600 seconds, is put once, and has no tokens.
public struct RelayBoxPutOptions: Sendable {
    public var ttl: RelayBoxTTL
    public var mode: RelayBoxPutMode
    public var readAuth: String?
    public var writeAuth: String?
    public init(ttl: RelayBoxTTL = .enrol, mode: RelayBoxPutMode = .create, readAuth: String? = nil, writeAuth: String? = nil) {
        self.ttl = ttl; self.mode = mode; self.readAuth = readAuth; self.writeAuth = writeAuth
    }
}

/// A message read from a box, still at the relay until `acknowledgeRelayBox`.
public struct FetchedBoxMessage: Sendable {
    public let message: Data
    /// The grant's mark (x-akr-stopped), if the relay sent one: nil for any other box.
    public let stopped: Bool?
    /// Each part's box and etag, part 0 first.
    let parts: [(id: String, etag: String)]
}

public struct RelayBoxClient: Sendable {
    public let url: String

    /// Tests that stand a relay up on 127.0.0.1 over plain http turn this on. Nothing else does.
    nonisolated(unsafe) public static var acceptsLoopbackForTests = false

    /// A relay URL this device may use: https with a host and nothing after the path (no user, password,
    /// query or fragment); plain http only to loopback in a test. Nil for anything else.
    public init?(checking text: String) {
        guard let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let loopback = host == "127.0.0.1" || host == "localhost"
        guard parts.scheme == "https" || (parts.scheme == "http" && loopback && Self.acceptsLoopbackForTests) else { return nil }
        url = text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// The relay a request's answers go to, only if it is the default or the one set on this device: a
    /// computer cannot point this device at any other address.
    public init?(for request: KeyringRequest) {
        let named = request.answerBoxURL.isEmpty ? RelayBoxProtocol.defaultURL : request.answerBoxURL
        guard let relay = RelayBoxClient(checking: named),
              relay.url == RelayBoxProtocol.defaultURL || relay.url == RelayBoxClient.configured.url else { return nil }
        self = relay
    }

    /// Test or app-launch override for the relay address.
    nonisolated(unsafe) public static var overrideURL: String?

    /// The relay this device uses: explicit override, then the environment, then the default.
    public static var configured: RelayBoxClient {
        let named = overrideURL ?? ProcessInfo.processInfo.environment["AGENT_KEYRING_RELAY_URL"]
        return named.flatMap(RelayBoxClient.init(checking:)) ?? RelayBoxClient(checking: RelayBoxProtocol.defaultURL)!
    }

    /// Seals a message into box `id` and the parts after it, the parts first, so whoever reads box `id`
    /// finds the rest, retrying each part while the relay cannot be reached or is busy (429, 5xx), until
    /// `giveUp`. Parts are created with the same ttl and no tokens; box `id` as `options` says. `stillTrying`
    /// is called each time a part is tried again.
    public func putRelayBox(_ message: Data, box id: String, key: Data, options: RelayBoxPutOptions = RelayBoxPutOptions(),
                    giveUp: Date = .now.addingTimeInterval(30), stillTrying: @Sendable () -> Void = {}) async throws {
        let parts = RelayBoxProtocol.splitIntoBoxChunks(message, box: id, nonce: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        guard parts.count <= RelayBoxProtocol.maxParts else { throw RelayBoxError.tooLarge }
        for index in parts.indices.reversed() {
            let sealed = try RelayBoxProtocol.sealBoxChunk(parts[index].plaintext, box: parts[index].id, key: key)
            _ = try await putPart(sealed, box: parts[index].id, options: index == 0 ? options : RelayBoxPutOptions(ttl: options.ttl), giveUp: giveUp,
                                  stillTrying: stillTrying)
        }
    }

    /// One sealed part. A create sent before without hearing back that is then found there (409) is taken
    /// as this put's own. Returns the relay's x-akr-stopped, for a grant.
    private func putPart(_ sealed: Data, box id: String, options: RelayBoxPutOptions, giveUp: Date,
                         stillTrying: @Sendable () -> Void = {}) async throws -> String? {
        var headers = ["x-akr-ttl": options.ttl.rawValue, "x-akr-mode": options.mode.rawValue]
        headers["x-akr-read-auth"] = options.readAuth
        headers["x-akr-write-auth"] = options.writeAuth
        var sent = false
        var wait = 0.5
        while true {
            do {
                let (status, _, response) = try await send("PUT", id, headers: headers, body: sealed)
                switch status {
                case 200, 201: return response.value(forHTTPHeaderField: "x-akr-stopped")
                case 409 where sent: return nil
                case 409: throw RelayBoxError.exists
                case 403: throw RelayBoxError.forbidden
                default: throw RelayBoxError.refused(status)
                }
            } catch let failure as RelayBoxError where failure.retryable {
                sent = true
                guard Date().addingTimeInterval(wait) < giveUp else { throw failure }
                stillTrying()
                try await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 2)
            }
        }
    }

    /// The message in box `id`, if one is there, left at the relay until `acknowledgeRelayBox`. A message whose later
    /// parts are missing is an error.
    public func fetchRelayBox(box id: String, key: Data, readAuth: String? = nil) async throws -> FetchedBoxMessage? {
        guard let (first, etag, stopped) = try await getPart(id, key: key, readAuth: readAuth) else { return nil }
        let count = first.count >= 20 ? first.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } : 0
        guard (1...UInt32(RelayBoxProtocol.maxParts)).contains(count) else { throw RelayBoxError.unreadable }
        let nonce = Data(first.dropFirst(4).prefix(16))
        var message = Data(first.dropFirst(20))
        var parts = [(id: id, etag: etag)]
        for index in 1..<max(1, count) {
            let partID = RelayBoxProtocol.partID(nonce: nonce, index)
            guard let (part, partEtag, _) = try await getPart(partID, key: key, readAuth: nil) else { throw RelayBoxError.missingPart }
            guard part.count >= 4, part.prefix(4) == first.prefix(4) else { throw RelayBoxError.unreadable }
            message += part.dropFirst(4)
            parts.append((partID, partEtag))
        }
        return FetchedBoxMessage(message: message, stopped: stopped, parts: parts)
    }

    private func getPart(_ id: String, key: Data, readAuth: String?) async throws -> (Data, String, Bool?)? {
        var headers: [String: String] = [:]
        headers["x-akr-read-auth"] = readAuth
        let (status, data, response) = try await send("GET", id, headers: headers)
        switch status {
        case 200: break
        case 404: return nil
        case 403: throw RelayBoxError.forbidden
        default: throw RelayBoxError.refused(status)
        }
        guard data.count <= RelayBoxProtocol.maxBoxBytes else { throw RelayBoxError.unreadable }
        let stopped: Bool? = switch response.value(forHTTPHeaderField: "x-akr-stopped") {
        case "true": true
        case "false": false
        default: nil
        }
        return (try RelayBoxProtocol.openBoxChunk(data, box: id, key: key), response.value(forHTTPHeaderField: "x-akr-etag") ?? "", stopped)
    }

    /// Deletes a message read with `fetchRelayBox`, once what it said is saved: each part only while it is the one
    /// read. A part already gone or replaced since (404, 409) is no error.
    public func acknowledgeRelayBox(_ picked: FetchedBoxMessage, readAuth: String? = nil) async throws {
        for (index, part) in picked.parts.enumerated() {
            var headers = ["x-akr-if-etag": part.etag]
            if index == 0 { headers["x-akr-read-auth"] = readAuth }
            let (status, _, _) = try await send("DELETE", part.id, headers: headers)
            guard [200, 404, 409].contains(status) else { throw RelayBoxError.refused(status) }
        }
    }

    /// Reads box `id` at `RelayBoxProtocol.pollInterval`'s pace from `started` until a message comes or `until` passes. A relay
    /// that cannot be reached for a moment is tried again. The message stays at the relay until `acknowledgeRelayBox`.
    func waitForRelayBox(box id: String, key: Data, readAuth: String? = nil, started: Date = .now, until: Date) async throws -> FetchedBoxMessage? {
        while Date() < until {
            try Task.checkCancellation()
            do {
                if let picked = try await fetchRelayBox(box: id, key: key, readAuth: readAuth) { return picked }
            } catch let failure as RelayBoxError where failure.retryable {}
            try await Task.sleep(for: RelayBoxProtocol.pollInterval(waited: Date().timeIntervalSince(started)))
        }
        return nil
    }

    /// Creates the grant of the request answered in `answerBox`: live, for 2700 seconds. One already
    /// there (409) is no error.
    public func publishLeaseGrantBox(answerBox: String, key: Data, requestID: String) async throws {
        let grant = LeaseGrantBox(answerBox: answerBox, key: key)
        do {
            try await putRelayBox(Data(requestID.utf8), box: grant.id, key: key,
                          options: RelayBoxPutOptions(ttl: .grant, mode: .create, readAuth: grant.readAuth, writeAuth: grant.writeAuth))
        } catch RelayBoxError.exists {}
    }

    /// Whether the grant of the request answered in `answerBox` still stands: true only if the relay
    /// marks it not stopped and it opens to this request. Nil if it says stopped; then `stop` is what it
    /// holds (the device's signed EndRequest, unchecked). Throws if the relay cannot say.
    public func readLeaseGrantBox(answerBox: String, key: Data, requestID: String) async throws -> (live: Bool, stop: Data?) {
        let grant = LeaseGrantBox(answerBox: answerBox, key: key)
        guard let picked = try await fetchRelayBox(box: grant.id, key: key, readAuth: grant.readAuth), let stopped = picked.stopped else {
            return (false, nil)
        }
        if stopped { return (false, picked.message) }
        return (picked.message == Data(requestID.utf8), nil)
    }

    /// Stop: marks the grant of the request answered in `answerBox` stopped, for good, with the device's
    /// signed EndRequest, creating the grant first in case the asking computer has not. True only once the
    /// relay says it is stopped, in its answer or, when that answer was lost, when the grant is read back.
    public func stopLeaseGrantBox(answerBox: String, key: Data, requestID: String, signedEnd: Data) async throws -> Bool {
        try await publishLeaseGrantBox(answerBox: answerBox, key: key, requestID: requestID)
        let grant = LeaseGrantBox(answerBox: answerBox, key: key)
        let sealed = try RelayBoxProtocol.sealBoxChunk(RelayBoxProtocol.bigEndian(1) + Data(count: 16) + signedEnd, box: grant.id, key: key)
        let mark = try await putPart(sealed, box: grant.id, options: RelayBoxPutOptions(ttl: .grant, mode: .stop, writeAuth: grant.writeAuth),
                                     giveUp: .now.addingTimeInterval(30))
        if mark == "true" { return true }
        return (try? await self.readLeaseGrantBox(answerBox: answerBox, key: key, requestID: requestID))?.stop != nil
    }

    /// One session for every box, following no redirects. A variable only so a test can use a relay in memory.
    nonisolated(unsafe) public static var session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// The box id goes in a header, never the URL, so nothing that logs URLs sees it. An unreachable relay
    /// is only its error code; a busy or failing one (429, 5xx) is retryable.
    private func send(_ method: String, _ id: String, headers: [String: String], body: Data? = nil) async throws
        -> (Int, Data, HTTPURLResponse) {
        guard let target = URL(string: "\(url)/v1/box") else { throw RelayBoxError.refused(0) }
        var request = URLRequest(url: target, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(id, forHTTPHeaderField: "x-akr-box")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await Self.session.data(for: request) }
        catch let error as URLError { throw error.code == .cancelled ? CancellationError() : RelayBoxError.unreachable(error.code.rawValue) }
        guard let http = response as? HTTPURLResponse else { throw RelayBoxError.refused(0) }
        if http.statusCode == 429 || http.statusCode >= 500 { throw RelayBoxError.refused(http.statusCode) }
        return (http.statusCode, data, http)
    }
}
