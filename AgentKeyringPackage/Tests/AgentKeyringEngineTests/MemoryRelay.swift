// Written by AI on 2026.11.24 by model claude opus 5.5.
//
// The box relay in memory, for tests of the apps' own code: every box request
// any test makes goes here instead of to push.opentrawl.sh, answered as it
// answers (keyring.proto, "Boxes"). The command's end-to-end tests
// run the real agent-keyring-box instead.

import AgentKeyringSealing
import CryptoKit
import Foundation

final class MemoryRelay: URLProtocol, @unchecked Sendable {
    static let url = "https://relay.test"

    private struct Held { var payload: Data; var etag: String; var expires: Date; var read: String?; var write: String?; var stopped: Bool? }
    nonisolated(unsafe) private static var boxes: [String: Held] = [:]
    nonisolated(unsafe) private static var intercepts: [String: @Sendable (URLRequest) -> (Int, Data, [String: String])?] = [:]
    private static let lock = NSLock()
    private static let ttls: [String: TimeInterval] = ["enrol": 600, "grant": 2700, "update": 604_800]

    static func setIntercept(for boxID: String, handler: (@Sendable (URLRequest) -> (Int, Data, [String: String])?)?) {
        lock.withLock { intercepts[boxID] = handler }
    }

    /// Every box request from now on goes to this relay, which the apps also take as the one set on this device.
    static func install() {
        RelayBoxClient.overrideURL = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryRelay.self]
        RelayBoxClient.session = URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let request = self.request
        let boxID = request.value(forHTTPHeaderField: "x-akr-box")
        let intercept = boxID.flatMap { id in Self.lock.withLock { Self.intercepts[id] } }
        if let intercept {
            let client = self.client
            let protocolInstance = self
            DispatchQueue.global().async {
                let (status, body, headers) = intercept(request) ?? Self.lock.withLock { Self.answer(request) }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(protocolInstance, didLoad: body)
                client?.urlProtocolDidFinishLoading(protocolInstance)
            }
            return
        }
        let (status, body, headers) = Self.lock.withLock { Self.answer(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func hash(_ token: String?) -> String? {
        token.map { Data(SHA256.hash(data: Data($0.utf8))).map { String(format: "%02x", $0) }.joined() }
    }

    private static func answer(_ request: URLRequest) -> (Int, Data, [String: String]) {
        guard let id = request.value(forHTTPHeaderField: "x-akr-box"), RelayBoxProtocol.isValidID(id) else { return (400, Data(), [:]) }
        let now = Date()
        let live = boxes[id].flatMap { $0.expires > now ? $0 : nil }
        let read = hash(request.value(forHTTPHeaderField: "x-akr-read-auth"))
        switch request.httpMethod {
        case "PUT":
            let ttlName = request.value(forHTTPHeaderField: "x-akr-ttl").flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "enrol"
            guard let ttl = Self.ttls[ttlName] else { return (400, Data(), [:]) }
            let mode = request.value(forHTTPHeaderField: "x-akr-mode").flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "create"
            guard ["create", "replace", "stop"].contains(mode) else { return (400, Data(), [:]) }
            let write = hash(request.value(forHTTPHeaderField: "x-akr-write-auth"))
            if mode != "create", write == nil { return (400, Data(), [:]) }
            if mode == "replace", ttlName == "grant" { return (400, Data(), [:]) }
            let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
            guard !body.isEmpty else { return (400, Data(), [:]) }
            let etag = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            if mode == "stop" {
                // Only a live grant stops, and a stopped grant stays stopped.
                guard var held = live, held.stopped != nil, held.write == write else { return (403, Data(), [:]) }
                held.payload = body; held.stopped = true; held.etag = etag; held.expires = now.addingTimeInterval(Self.ttls["grant"]!)
                boxes[id] = held
                return (200, Data(), ["x-akr-etag": etag, "x-akr-stopped": "true"])
            }
            // A replace never touches a live grant: that would clear its Stop.
            if let live, mode == "create" || live.write != write || live.stopped != nil {
                return (mode == "replace" ? 403 : 409, Data(), [:])
            }
            let stopped: Bool? = ttlName == "grant" && mode == "create" ? false : nil
            boxes[id] = Held(payload: body, etag: etag, expires: now.addingTimeInterval(ttl), read: read, write: write, stopped: stopped)
            return (201, Data(), stopped == nil ? ["x-akr-etag": etag] : ["x-akr-etag": etag, "x-akr-stopped": "false"])
        case "GET":
            guard let live else { return (404, Data(), [:]) }
            guard live.read == nil || live.read == read else { return (403, Data(), [:]) }
            var headers = ["x-akr-etag": live.etag]
            if let stopped = live.stopped { headers["x-akr-stopped"] = stopped ? "true" : "false" }
            return (200, live.payload, headers)
        case "DELETE":
            let ifEtag = request.value(forHTTPHeaderField: "x-akr-if-etag")
            let allowed = (live?.read == nil || live?.read == read) && live?.stopped == nil && (ifEtag == nil || live?.etag == ifEtag)
            guard allowed else { return (ifEtag == nil ? 403 : 409, Data(), [:]) }
            boxes[id] = nil
            return live.map { (200, $0.payload, ["x-akr-etag": $0.etag]) } ?? (404, Data(), [:])
        default:
            return (405, Data(), [:])
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
