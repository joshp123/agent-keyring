// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// K-anonymous site icon store for macOS and iOS.
//
// Resolution order:
//   1. Bundled offline pack (`SiteIcons.bin`, memory-mapped, zero network)
//   2. On-disk cached k-anonymous bucket (`<cacheDir>/<14-bit-sha256>.bin`)
//   3. Static CDN fetch: `GET <baseURL>/<14-bit-sha256>.bin` (ephemeral session,
//      no cookies, no domain names on the wire, private/local/IP hosts skipped).

import CryptoKit
import Foundation

public final class SiteIconStore: Sendable {
    public static let defaultBaseURL = URL(string: "https://keyring.opentrawl.sh/icons/v1/")!
    public static let prefixBits = 14
    public static let optOutDefaultsKey = "no_site_icon_buckets"

    public static let shared = SiteIconStore()

    private let baseURL: URL
    private let cacheDirectory: URL
    private let bundledPack: AKICPack?
    private let psl: PublicSuffixList
    private let session: URLSession
    private let remoteBucketsEnabledOverride: Bool?
    private let bucketCache = BucketCacheActor()

    public var bundledIconCount: Int {
        bundledPack?.count ?? 0
    }

    public init(
        baseURL: URL = SiteIconStore.defaultBaseURL,
        cacheDirectory: URL? = nil,
        bundledPackURL: URL? = SiteIconBundle.url,
        psl: PublicSuffixList = .shared,
        session: URLSession? = nil,
        remoteBucketsEnabled: Bool? = nil
    ) {
        self.baseURL = baseURL
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.bundledPack = bundledPackURL.flatMap { AKICPack(contentsOf: $0) }
        self.psl = psl
        self.session = session ?? Self.makeEphemeralSession()
        self.remoteBucketsEnabledOverride = remoteBucketsEnabled
    }

    /// 14-bit SHA-256 prefix formatted as 4 lowercase hex digits (`0000`...`3fff`).
    public static func bucketID(forETLD1 domain: String) -> String {
        let digest = Array(SHA256.hash(data: Data(domain.utf8)))
        let value = ((UInt16(digest[0]) << 8) | UInt16(digest[1])) >> (16 - prefixBits)
        return String(format: "%04x", value)
    }

    /// Returns whether the bundled offline pack holds an icon for `host`.
    public func hasBundledIcon(forHost host: String, displayName: String = "") -> Bool {
        guard let bundledPack else { return false }
        return lookupKeys(rawHost: host, displayName: displayName).contains { bundledPack.contains($0) }
    }

    /// Synchronous lookup across the bundled offline pack and previously downloaded
    /// on-disk k-anonymous buckets. Never performs network I/O.
    public func cachedIconData(forHost host: String, displayName: String = "") -> Data? {
        if let bundled = bundledIconData(forHost: host, displayName: displayName) {
            return bundled
        }
        guard let etld = psl.etld1(for: host) else { return nil }
        let bid = Self.bucketID(forETLD1: etld)
        let fileURL = cacheDirectory.appendingPathComponent("\(bid).bin", isDirectory: false)
        guard let pack = AKICPack(contentsOf: fileURL) else { return nil }
        return pack.iconData(for: etld)
    }

    /// Resolves icon bytes (WebP or PNG), fetching at most one k-anonymous static
    /// bucket on a cache miss. Returns `nil` with zero network traffic for private,
    /// local, IP-address, or tailnet hosts, or when remote buckets are disabled.
    public func iconData(forHost host: String, displayName: String = "") async -> Data? {
        if let bundled = bundledIconData(forHost: host, displayName: displayName) {
            return bundled
        }
        guard let etld = psl.etld1(for: host) else { return nil }
        let bid = Self.bucketID(forETLD1: etld)

        if let cached = await bucketCache.cachedPack(for: bid, cacheDirectory: cacheDirectory) {
            return cached?.iconData(for: etld)
        }
        guard isRemoteBucketsEnabled else { return nil }

        let pack = await bucketCache.fetchPack(
            bucketID: bid,
            baseURL: baseURL,
            cacheDirectory: cacheDirectory,
            session: session
        )
        return pack?.iconData(for: etld)
    }

    public var isRemoteBucketsEnabled: Bool {
        if let override = remoteBucketsEnabledOverride {
            return override
        }
        if ProcessInfo.processInfo.environment["AGENT_KEYRING_NO_ICON_BUCKETS"] == "1" {
            return false
        }
        return !UserDefaults.standard.bool(forKey: Self.optOutDefaultsKey)
    }

    private func bundledIconData(forHost host: String, displayName: String) -> Data? {
        guard let bundledPack else { return nil }
        for key in lookupKeys(rawHost: host, displayName: displayName) {
            if let data = bundledPack.iconData(for: key) {
                return data
            }
        }
        return nil
    }

    public func lookupKeys(rawHost: String, displayName: String) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        func add(_ k: String) {
            let clean = k.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return }
            keys.append(clean)
        }

        let normalised = PublicSuffixList.normaliseHost(rawHost)
        if !normalised.isEmpty {
            add(normalised)
            if let etld = psl.etld1(for: normalised) {
                add(etld)
                if let alias = Self.hostAliases[etld] { add(alias) }
            }
            if let alias = Self.hostAliases[normalised] { add(alias) }
            if let first = normalised.split(separator: ".").first.map(String.init),
               let alias = Self.regionalAliases[first]
            {
                add(alias)
            }
        }

        let lowerName = displayName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = Self.nameAliases[lowerName] { add(mapped) }
        return keys
    }

    private static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("AgentKeyring", isDirectory: true)
            .appendingPathComponent("SiteIcons", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private static func makeEphemeralSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.httpAdditionalHeaders = ["User-Agent": "AgentKeyring/1"]
        return URLSession(configuration: cfg)
    }

    private static let hostAliases: [String: String] = [
        "twitter.com": "x.com",
        "gmail.com": "mail.google.com",
        "outlook.com": "outlook.live.com",
        "live.com": "outlook.live.com",
        "office.com": "outlook.live.com",
        "cursor.sh": "cursor.com",
        "anthropic.com": "claude.ai",
        "console.anthropic.com": "claude.ai",
        "hmrc.gov.uk": "gov.uk",
        "transferwise.com": "wise.com",
    ]

    private static let regionalAliases: [String: String] = [
        "amazon": "amazon.com",
        "ebay": "ebay.com",
        "deliveroo": "deliveroo.co.uk",
        "zalando": "zalando.com",
        "airbnb": "airbnb.com",
        "barclays": "barclays.co.uk",
        "hsbc": "hsbc.co.uk",
    ]

    private static let nameAliases: [String: String] = [
        "github": "github.com",
        "aws": "aws.amazon.com",
        "google cloud": "cloud.google.com",
        "cloudflare": "cloudflare.com",
        "docker": "docker.com",
        "vercel": "vercel.com",
        "openai": "openai.com",
        "chatgpt": "chatgpt.com",
        "claude": "claude.ai",
        "anthropic": "claude.ai",
        "cursor": "cursor.com",
        "hugging face": "huggingface.co",
        "elevenlabs": "elevenlabs.io",
        "youtube": "youtube.com",
        "instagram": "instagram.com",
        "reddit": "reddit.com",
        "x": "x.com",
        "linkedin": "linkedin.com",
        "discord": "discord.com",
        "gmail": "mail.google.com",
        "outlook": "outlook.live.com",
        "slack": "slack.com",
        "zoom": "zoom.us",
        "notion": "notion.so",
        "amazon": "amazon.com",
        "ebay": "ebay.com",
        "aliexpress": "aliexpress.com",
        "ikea": "ikea.com",
        "deliveroo": "deliveroo.co.uk",
        "wise": "wise.com",
        "revolut": "revolut.com",
        "coinbase": "coinbase.com",
        "hmrc": "gov.uk",
    ]
}

// MARK: - Coalesced Bucket Cache

private actor BucketCacheActor {
    private enum Entry {
        case hit(AKICPack)
        case miss
    }

    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<AKICPack?, Never>] = [:]

    func cachedPack(for bucketID: String, cacheDirectory: URL) -> AKICPack?? {
        if let entry = memory[bucketID] {
            switch entry {
            case .hit(let pack): return .some(pack)
            case .miss: return .some(nil)
            }
        }
        let fileURL = cacheDirectory.appendingPathComponent("\(bucketID).bin", isDirectory: false)
        if let pack = AKICPack(contentsOf: fileURL) {
            memory[bucketID] = .hit(pack)
            return .some(pack)
        }
        return .none
    }

    func fetchPack(
        bucketID: String,
        baseURL: URL,
        cacheDirectory: URL,
        session: URLSession
    ) async -> AKICPack? {
        if let entry = memory[bucketID] {
            switch entry {
            case .hit(let pack): return pack
            case .miss: return nil
            }
        }
        if let existing = inFlight[bucketID] {
            return await existing.value
        }

        let task = Task<AKICPack?, Never> {
            let fileURL = cacheDirectory.appendingPathComponent("\(bucketID).bin", isDirectory: false)
            if let pack = AKICPack(contentsOf: fileURL) {
                return pack
            }
            let url = baseURL.appendingPathComponent("\(bucketID).bin", isDirectory: false)
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return nil
                }
                guard let pack = AKICPack(data: data) else {
                    return nil
                }
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
                return pack
            } catch {
                return nil
            }
        }

        inFlight[bucketID] = task
        let result = await task.value
        inFlight[bucketID] = nil
        if let result {
            memory[bucketID] = .hit(result)
        } else {
            memory[bucketID] = .miss
        }
        return result
    }
}
