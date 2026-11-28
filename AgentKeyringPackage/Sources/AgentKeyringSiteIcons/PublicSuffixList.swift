// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Offline Public Suffix List (PSL) eTLD+1 extractor used to canonicalise saved
// website hosts before hashing into k-anonymous icon buckets, while keeping all
// local, IP-address, and tailnet hostnames strictly off the wire.

import Foundation

public final class PublicSuffixList: Sendable {
    public static let shared = PublicSuffixList()

    private let exactRules: Set<String>
    private let wildcardRules: Set<String>
    private let exceptionRules: Set<String>

    public var ruleCount: Int {
        exactRules.count + wildcardRules.count + exceptionRules.count
    }

    public convenience init() {
        if let url = SiteIconBundle.pslURL,
           let compressed = try? Data(contentsOf: url),
           let raw = Self.decompressZlib(compressed),
           let text = String(data: raw, encoding: .utf8)
        {
            self.init(rulesText: text)
        } else {
            self.init(rulesText: "")
        }
    }

    public init(rulesText: String) {
        var exact = Set<String>()
        var wildcard = Set<String>()
        var exception = Set<String>()
        exact.reserveCapacity(10_500)

        rulesText.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !line.isEmpty, !line.hasPrefix("//") else { return }
            if line.hasPrefix("!") {
                exception.insert(String(line.dropFirst()))
            } else if line.hasPrefix("*.") {
                wildcard.insert(String(line.dropFirst(2)))
            } else {
                exact.insert(line)
            }
        }
        self.exactRules = exact
        self.wildcardRules = wildcard
        self.exceptionRules = exception
    }

    /// Normalises a URL or bare host string to a lowercase hostname without `www.`.
    public static func normaliseHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let host = (URL(string: candidate)?.host ?? trimmed)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Returns true for IP addresses, single-label hosts, and private/local/tailnet suffixes.
    public static func isPrivateOrIP(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains("."), host != "localhost" else { return true }
        let blockedSuffixes = [".local", ".lan", ".internal", ".ts.net", ".home", ".arpa", ".localhost"]
        if blockedSuffixes.contains(where: { host.hasSuffix($0) }) {
            return true
        }
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return true
        }
        return false
    }

    /// Extracts the public registrable domain (eTLD+1) for `raw`, or `nil` for private/IP/bare-suffix hosts.
    public func etld1(for raw: String) -> String? {
        let host = Self.normaliseHost(raw)
        guard !Self.isPrivateOrIP(host) else { return nil }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }

        var suffixLabels = 1
        for i in 0..<parts.count {
            let sub = parts[i...].joined(separator: ".")
            if exceptionRules.contains(sub) {
                suffixLabels = parts.count - i - 1
                break
            }
            if exactRules.contains(sub) {
                suffixLabels = max(suffixLabels, parts.count - i)
                break
            }
            if i + 1 < parts.count {
                let parent = parts[(i + 1)...].joined(separator: ".")
                if wildcardRules.contains(parent) {
                    suffixLabels = max(suffixLabels, parts.count - i)
                    break
                }
            }
        }
        guard parts.count > suffixLabels else { return nil }
        return parts[(parts.count - suffixLabels - 1)...].joined(separator: ".")
    }

    /// Decompresses either raw RFC 1951 deflate or RFC 1950 zlib-wrapped payloads.
    private static func decompressZlib(_ data: Data) -> Data? {
        if let direct = try? (data as NSData).decompressed(using: .zlib) as Data {
            return direct
        }
        // RFC 1950 zlib stream: 2-byte header (typically 0x78 ...) + raw deflate + 4-byte Adler-32.
        guard data.count > 6 else { return nil }
        let stripped = data.subdata(in: 2..<(data.count - 4))
        return try? (stripped as NSData).decompressed(using: .zlib) as Data
    }
}
