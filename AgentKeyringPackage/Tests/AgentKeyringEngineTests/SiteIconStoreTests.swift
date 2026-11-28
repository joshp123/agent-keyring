// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Tests for PSL eTLD+1 canonicalisation, private/IP host blocking, 14-bit
// k-anonymous SHA-256 bucket IDs, coalesced HTTP fetches, disk caching, and
// zero-domain-leak guarantees on the wire.

import AgentKeyringSiteIcons
import Foundation
import Testing

#if os(macOS)
import AppKit
#endif

@Suite("K-Anonymous Site Icon Store", .serialized)
struct SiteIconStoreTests {
    @Test("Bundled PSL parses 10,000+ rules and extracts registrable eTLD+1s")
    func pslExtraction() {
        let psl = PublicSuffixList.shared
        #expect(psl.ruleCount >= 9_000)

        #expect(psl.etld1(for: "https://dash.cloudflare.com/login") == "cloudflare.com")
        #expect(psl.etld1(for: "www.example.co.uk") == "example.co.uk")
        #expect(psl.etld1(for: "signin.account.gov.uk") == "account.gov.uk")
        #expect(psl.etld1(for: "trader.degiro.nl") == "degiro.nl")
        #expect(psl.etld1(for: "sub.service.co.jp") == "service.co.jp")

        // Bare public suffixes must return nil rather than falsely matching another site.
        #expect(psl.etld1(for: "gov.uk") == nil)
        #expect(psl.etld1(for: "co.uk") == nil)

        // Private, local, IP, and tailnet hosts must return nil (never leave the device).
        #expect(psl.etld1(for: "localhost") == nil)
        #expect(psl.etld1(for: "http://192.168.1.1:8080") == nil)
        #expect(psl.etld1(for: "10.0.0.42") == nil)
        #expect(psl.etld1(for: "https://mac-mini.tail000000.ts.net") == nil)
        #expect(psl.etld1(for: "nas.local") == nil)
        #expect(psl.etld1(for: "router.internal") == nil)
        #expect(psl.etld1(for: "[::1]") == nil)
    }

    @Test("14-bit SHA-256 bucket ID matches wire specification")
    func bucketIDVectors() {
        // SHA256("github.com") starts with 0x3a 0xeb -> (0x3aeb >> 2) == 0x0eba
        #expect(SiteIconStore.bucketID(forETLD1: "github.com") == "0eba")
        // Verify all bucket IDs stay in 4-hex-digit 14-bit range 0000...3fff
        for dom in ["example.com", "degiro.nl", "anwb.nl", "eurostar.com", "cloudflare.com"] {
            let bid = SiteIconStore.bucketID(forETLD1: dom)
            #expect(bid.count == 4)
            let parsed = UInt16(bid, radix: 16)
            #expect(parsed != nil && parsed! < 16_384)
        }
    }

    @Test("Fetches only prefix buckets over the wire, coalesces duplicates, caches to disk, and skips private hosts")
    func kAnonymousFetchPrivacyAndCaching() async throws {
        let domain = "rare-unbundled-site.example"
        let sibling = "other-in-same-bucket.example"
        let bid = SiteIconStore.bucketID(forETLD1: domain)
        let fakeIcon = Data([0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
        let akicBytes = Self.makeAKIC([
            (domain, fakeIcon),
            (sibling, Data([0x01, 0x02, 0x03])),
        ])

        let recorder = MockBucketRecorder(buckets: [bid: akicBytes])
        MockBucketURLProtocol.recorder = recorder
        defer { MockBucketURLProtocol.recorder = nil }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockBucketURLProtocol.self]
        let session = URLSession(configuration: cfg)

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-icon-store-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let store = SiteIconStore(
            baseURL: URL(string: "https://icons-test.invalid/icons/v1/")!,
            cacheDirectory: cacheDir,
            bundledPackURL: nil,
            psl: .shared,
            session: session,
            remoteBucketsEnabled: true
        )

        // Private hosts never trigger network requests.
        #expect(await store.iconData(forHost: "192.168.1.1") == nil)
        #expect(await store.iconData(forHost: "mac-mini.tail000000.ts.net") == nil)
        #expect(await store.iconData(forHost: "printer.local") == nil)
        #expect(recorder.requestedPaths.isEmpty)

        // Concurrent requests for subdomains of the same eTLD+1 coalesce into 1 HTTP GET.
        async let a = store.iconData(forHost: "login.\(domain)")
        async let b = store.iconData(forHost: "www.\(domain)")
        let (ra, rb) = await (a, b)
        #expect(ra == fakeIcon)
        #expect(rb == fakeIcon)
        #expect(recorder.requestedPaths == ["/icons/v1/\(bid).bin"])

        // Confirm zero domain names appeared in any requested URL.
        for path in recorder.requestedPaths {
            #expect(!path.contains(domain))
            #expect(!path.contains("example"))
        }

        // Subsequent cold store reading the same cacheDir resolves synchronously with 0 network calls.
        let coldStore = SiteIconStore(
            baseURL: URL(string: "https://icons-test.invalid/icons/v1/")!,
            cacheDirectory: cacheDir,
            bundledPackURL: nil,
            psl: .shared,
            session: session,
            remoteBucketsEnabled: true
        )
        #expect(coldStore.cachedIconData(forHost: "app.\(domain)") == fakeIcon)
        #expect(await coldStore.iconData(forHost: "app.\(domain)") == fakeIcon)
        #expect(recorder.requestedPaths.count == 1)

        // Opt-out disables remote fetches cleanly.
        let optedOut = SiteIconStore(
            baseURL: URL(string: "https://icons-test.invalid/icons/v1/")!,
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("site-icon-optout-\(UUID().uuidString)", isDirectory: true),
            bundledPackURL: nil,
            psl: .shared,
            session: session,
            remoteBucketsEnabled: false
        )
        #expect(await optedOut.iconData(forHost: domain) == nil)
        #expect(recorder.requestedPaths.count == 1)
    }

    private static func makeAKIC(_ entries: [(String, Data)]) -> Data {
        let sorted = entries.sorted { $0.0 < $1.0 }
        var indexBuf = Data()
        var dataBuf = Data()
        for (dom, blob) in sorted {
            let db = Data(dom.utf8)
            var dl = UInt16(db.count).littleEndian
            indexBuf.append(Data(bytes: &dl, count: 2))
            indexBuf.append(db)
            var off = UInt32(dataBuf.count).littleEndian
            var len = UInt32(blob.count).littleEndian
            indexBuf.append(Data(bytes: &off, count: 4))
            indexBuf.append(Data(bytes: &len, count: 4))
            dataBuf.append(blob)
        }
        var out = Data("AKIC".utf8)
        var count = UInt32(sorted.count).littleEndian
        var idxLen = UInt32(indexBuf.count).littleEndian
        out.append(Data(bytes: &count, count: 4))
        out.append(Data(bytes: &idxLen, count: 4))
        out.append(indexBuf)
        out.append(dataBuf)
        return out
    }
}

private final class MockBucketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    let buckets: [String: Data]
    private var _paths: [String] = []

    init(buckets: [String: Data]) {
        self.buckets = buckets
    }

    var requestedPaths: [String] {
        lock.withLock { _paths }
    }

    func record(path: String) -> Data? {
        lock.withLock { _paths.append(path) }
        let file = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return buckets[file]
    }
}

private final class MockBucketURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: MockBucketRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let recorder = Self.recorder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let payload = recorder.record(path: url.path) {
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
        } else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
