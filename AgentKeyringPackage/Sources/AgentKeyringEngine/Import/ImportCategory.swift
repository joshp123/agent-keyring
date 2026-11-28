// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Offline category matching for selective password import and sidebar
// filtering. Uses a bundled 500,000-domain sorted catalogue with zero-copy
// UTF-8 binary search, plus deterministic private-network and government-TLD
// rules. Domains absent from the table return nil so on-device Apple
// Intelligence can classify them in the background.

import AgentKeyringApprovalCore
import Foundation

/// Offline classifier mapping websites and StoredVaultLogin items to an `ImportCategory`.
public enum DomainClassifier {
    /// Total number of categorised domains loaded from the bundled offline catalogue.
    public static var bundledDomainCount: Int {
        OfflineDomainCatalogue.shared.count
    }

    /// Forces the bundled offline catalogue into memory (safe to call off the main thread).
    static func warmCatalogue() {
        _ = OfflineDomainCatalogue.shared.count
    }

    /// Classifies an imported item using its origins (and title as fallback).
    /// Sensitive (banking, crypto, government) always wins if any origin matches.
    /// Returns nil when no origin is in the offline catalogue or deterministic rules
    /// (signalling that on-device Apple Intelligence should sort it).
    public static func classify(_ item: StoredVaultLogin) -> ImportCategory? {
        let hosts = extractHosts(origins: item.origins, title: item.title)
        return classifyHosts(hosts)
    }

    /// Classifies a single URL or hostname string.
    /// Returns nil when absent from the offline catalogue and deterministic rules.
    public static func classify(site: String) -> ImportCategory? {
        let hosts = extractHosts(origins: [site], title: "")
        return classifyHosts(hosts)
    }

    /// Best human-readable primary host for display (e.g. "dash.cloudflare.com").
    static func primaryHost(origins: [String], title: String) -> String {
        if let first = extractHosts(origins: origins, title: "").first {
            return first
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown site" : trimmed
    }

    /// Canonical cache key for an item's primary host (or lowercased title fallback).
    static func cacheKey(origins: [String], title: String) -> String {
        if let first = extractHosts(origins: origins, title: "").first {
            return first
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Canonical cache key for a single site string.
    static func cacheKey(site: String) -> String {
        if let host = normaliseHost(site) {
            return host
        }
        return site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Short brand or site display name for review rows and receipt chips.
    public static func displayName(origins: [String], title: String) -> String {
        let hosts = extractHosts(origins: origins, title: title)
        for host in hosts {
            if let exact = exactDisplayNames[host] { return exact }
            let root = rootDomain(for: host)
            if let mapped = rootDisplayNames[root] { return mapped }
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = hosts.first {
            let root = rootDomain(for: host)
            let label = root.split(separator: ".").first.map(String.init) ?? host
            return label.prefix(1).uppercased() + label.dropFirst()
        }
        return "Password"
    }

    // MARK: Classification pipeline

    private static func classifyHosts(_ hosts: [String]) -> ImportCategory? {
        var firstNonSensitive: ImportCategory?
        for host in hosts {
            guard let cat = classifySingleHost(host) else { continue }
            if cat == .sensitive { return .sensitive }
            if firstNonSensitive == nil { firstNonSensitive = cat }
        }
        return firstNonSensitive
    }

    private static func classifySingleHost(_ host: String) -> ImportCategory? {
        // 1. Private / LAN hosts and RFC 1918 IPv4 addresses always belong in Home & Devices.
        if isPrivateNetworkHost(host) {
            return .homeDevices
        }

        // 2. Customer subdomains on multi-tenant app or SSO hosts are sent to Apple Intelligence
        // rather than inheriting the hosting vendor's category.
        let root = rootDomain(for: host)
        if multiTenantRoots.contains(root), host != root {
            return nil
        }

        // 3. Exact host and parent-subdomain lookup in the 500k offline catalogue.
        if let bundled = OfflineDomainCatalogue.shared.category(forHost: host, root: root) {
            return bundled
        }

        // 4. Structural government TLD safety floor for unlisted public-sector subdomains.
        for suffix in governmentSuffixes where host == suffix || host.hasSuffix(".\(suffix)") {
            return .sensitive
        }

        // Absent from the 500k table: let on-device Apple Intelligence classify it.
        return nil
    }

    // MARK: Host parsing

    static func extractHosts(origins: [String], title: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            guard let host = normaliseHost(raw), seen.insert(host).inserted else { return }
            result.append(host)
        }
        for origin in origins { add(origin) }
        if result.isEmpty { add(title) }
        return result
    }

    static func normaliseHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: candidate)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let cleaned = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard cleaned == "localhost" || cleaned.contains(".") else { return nil }
        return cleaned.hasPrefix("www.") ? String(cleaned.dropFirst(4)) : cleaned
    }

    static func rootDomain(for host: String) -> String {
        if isIPv4Address(host) { return host }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host }
        if parts.count >= 3, multiPartTLDs.contains("\(parts[parts.count - 2]).\(parts[parts.count - 1])") {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    static func isPrivateNetworkHost(_ host: String) -> Bool {
        if host == "localhost"
            || host.hasSuffix(".local")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".home")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".home.arpa")
        {
            return true
        }
        let parts = host.split(separator: ".")
        if parts.count == 4,
           let a = UInt8(parts[0]),
           let b = UInt8(parts[1]),
           UInt8(parts[2]) != nil,
           UInt8(parts[3]) != nil
        {
            if a == 10 || a == 127 { return true }
            if a == 192 && b == 168 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 100 && (64...127).contains(b) { return true } // Tailscale / CGNAT
        }
        return false
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: Compact structural sets

    private static let multiPartTLDs: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "nhs.uk", "sch.uk",
        "com.au", "net.au", "org.au", "gov.au", "edu.au",
        "co.nz", "govt.nz", "org.nz",
        "co.jp", "ne.jp", "or.jp", "go.jp",
        "com.br", "gov.br", "org.br",
        "com.mx", "gob.mx",
        "co.in", "gov.in", "nic.in",
        "co.za", "gov.za",
        "com.sg", "gov.sg",
        "com.hk", "gov.hk",
        "com.be", "co.il", "co.kr", "com.tr", "com.tw", "com.cn", "gov.cn",
        "com.pl", "com.ar", "com.ua", "com.my", "com.ph", "com.vn", "co.id", "co.th",
        "gouv.fr", "gob.es", "gv.at", "gov.ie", "gov.ca", "gc.ca", "gov.nl",
    ]

    private static let governmentSuffixes: [String] = [
        "gov", "mil",
        "gov.uk", "nhs.uk", "nhs.net", "gov.scot", "gov.wales",
        "gov.au", "gov.ca", "gc.ca", "gov.sg", "gov.in", "gov.ie", "govt.nz",
        "gouv.fr", "gob.es", "gob.mx", "gov.br", "gov.za", "gov.hk", "go.jp", "gv.at",
        "gov.it", "gov.pt", "gov.pl", "gov.be", "gov.gr", "gov.nl",
        "overheid.nl", "mijnoverheid.nl", "rijksoverheid.nl",
    ]

    private static let multiTenantRoots: Set<String> = [
        "auth0.com", "okta.com", "oktapreview.com", "b2clogin.com",
        "firebaseapp.com", "web.app", "herokuapp.com", "vercel.app",
        "netlify.app", "pages.dev", "workers.dev", "github.io", "gitlab.io",
    ]

    private static let exactDisplayNames: [String: String] = [
        "mail.google.com": "Gmail",
        "console.cloud.google.com": "Google Cloud",
        "cloud.google.com": "Google Cloud",
        "gemini.google.com": "Google Gemini",
        "aistudio.google.com": "Google AI Studio",
        "console.aws.amazon.com": "AWS",
        "signin.aws.amazon.com": "AWS",
        "aws.amazon.com": "AWS",
        "console.anthropic.com": "Claude",
        "platform.openai.com": "OpenAI",
        "dash.cloudflare.com": "Cloudflare",
    ]

    private static let rootDisplayNames: [String: String] = [
        "github.com": "GitHub", "gitlab.com": "GitLab", "cloudflare.com": "Cloudflare",
        "vercel.com": "Vercel", "docker.com": "Docker", "hetzner.com": "Hetzner",
        "digitalocean.com": "DigitalOcean", "supabase.com": "Supabase", "stripe.com": "Stripe",
        "openai.com": "OpenAI", "chatgpt.com": "ChatGPT", "anthropic.com": "Claude",
        "claude.ai": "Claude", "cursor.com": "Cursor", "cursor.sh": "Cursor",
        "huggingface.co": "Hugging Face", "elevenlabs.io": "ElevenLabs",
        "perplexity.ai": "Perplexity", "deepseek.com": "DeepSeek", "ollama.com": "Ollama",
        "youtube.com": "YouTube", "instagram.com": "Instagram", "reddit.com": "Reddit",
        "x.com": "X", "twitter.com": "X", "linkedin.com": "LinkedIn", "discord.com": "Discord",
        "facebook.com": "Facebook", "tiktok.com": "TikTok",
        "gmail.com": "Gmail", "google.com": "Google", "outlook.com": "Outlook",
        "slack.com": "Slack", "zoom.us": "Zoom", "notion.so": "Notion", "linear.app": "Linear",
        "atlassian.com": "Atlassian", "figma.com": "Figma",
        "amazon.com": "Amazon", "amazon.co.uk": "Amazon", "amazon.nl": "Amazon",
        "amazon.de": "Amazon", "ebay.com": "eBay", "ebay.co.uk": "eBay",
        "aliexpress.com": "AliExpress", "ikea.com": "IKEA", "deliveroo.co.uk": "Deliveroo",
        "wise.com": "Wise", "revolut.com": "Revolut", "coinbase.com": "Coinbase",
        "hmrc.gov.uk": "HMRC", "binance.com": "Binance", "kraken.com": "Kraken",
        "monzo.com": "Monzo", "paypal.com": "PayPal", "chase.com": "Chase",
        "1password.com": "1Password", "bitwarden.com": "Bitwarden",
    ]
}

// MARK: - Bundled 500,000+ Offline Domain Catalogue (Zero-Copy Sorted Binary Search)

private final class OfflineDomainCatalogue: Sendable {
    static let shared = OfflineDomainCatalogue()

    private let rawBytes: Data
    private let lineStarts: [UInt32]

    var count: Int { lineStarts.count }

    private init() {
        guard let url = Bundle.module.url(forResource: "DomainCatalogue.tsv", withExtension: "zlib")
            ?? Bundle.module.url(forResource: "DomainCatalogue", withExtension: "tsv.zlib"),
              let compressed = try? Data(contentsOf: url),
              let decompressed = try? (compressed as NSData).decompressed(using: .zlib) as Data
        else {
            self.rawBytes = Data()
            self.lineStarts = []
            return
        }

        var starts: [UInt32] = []
        starts.reserveCapacity(505_000)

        decompressed.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let total = buffer.count
            var offset = 0
            while offset < total {
                let lineStart = offset
                var cursor = offset
                while cursor < total && base[cursor] != 0x0A {
                    cursor += 1
                }
                if cursor > lineStart {
                    starts.append(UInt32(lineStart))
                }
                offset = cursor + 1
            }
        }

        self.rawBytes = decompressed
        self.lineStarts = starts
    }

    func category(forHost host: String, root: String) -> ImportCategory? {
        if let exact = lookupExact(host) { return exact }
        var parts = host.split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeFirst()
            let parent = parts.joined(separator: ".")
            if let hit = lookupExact(parent) { return hit }
        }
        return lookupExact(root)
    }

    private func lookupExact(_ domain: String) -> ImportCategory? {
        guard !lineStarts.isEmpty else { return nil }
        return domain.utf8.withContiguousStorageIfAvailable { target in
            binarySearch(target: target)
        } ?? {
            let bytes = Array(domain.utf8)
            return bytes.withUnsafeBufferPointer { binarySearch(target: $0) }
        }()
    }

    private func binarySearch(target: UnsafeBufferPointer<UInt8>) -> ImportCategory? {
        guard let targetBase = target.baseAddress else { return nil }
        let targetCount = target.count

        return rawBytes.withUnsafeBytes { rawBuffer -> ImportCategory? in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let totalBytes = rawBuffer.count
            var low = 0
            var high = lineStarts.count - 1

            while low <= high {
                let mid = (low + high) >> 1
                let start = Int(lineStarts[mid])
                var tab = start
                while tab < totalBytes && base[tab] != 0x09 && base[tab] != 0x0A {
                    tab += 1
                }
                let keyLen = tab - start
                let minLen = min(keyLen, targetCount)
                var cmp = 0
                var i = 0
                while i < minLen {
                    let a = base[start + i]
                    let b = targetBase[i]
                    if a != b {
                        cmp = a < b ? -1 : 1
                        break
                    }
                    i += 1
                }
                if cmp == 0 {
                    if keyLen == targetCount {
                        let codePos = tab + 1
                        if tab < totalBytes && base[tab] == 0x09 && codePos < totalBytes {
                            return ImportCategory.fromCodeByte(base[codePos])
                        }
                        return nil
                    }
                    cmp = keyLen < targetCount ? -1 : 1
                }
                if cmp < 0 {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return nil
        }
    }
}
