// Written by AI on 2026.11.23 by model gemini-4-neon.
//
// Zero-PII daily version check against https://push.opentrawl.sh/v1/version.
// Sends only app version, platform, CPU architecture, and a monthly-rotated
// anonymous hash (no IP stored server-side, no usernames, sites, or passwords).
// Opt out via AGENT_KEYRING_NO_TELEMETRY=1 or UserDefaults "disableVersionCheck".

import CryptoKit
import Foundation

public enum VersionCheck {
    public struct Status: Sendable, Decodable {
        public let latest: String
        public let url: String
        public let testflight: String?
    }

    public static let endpoint = URL(string: "https://push.opentrawl.sh/v1/version")!
    private static let disabledKey = "disableVersionCheck"
    private static let lastCheckKey = "lastVersionCheckUnix"
    private static let installSeedKey = "versionCheckSeed"
    private static let intervalSeconds: TimeInterval = 24 * 60 * 60

    public static var isDisabled: Bool {
        if ProcessInfo.processInfo.environment["AGENT_KEYRING_NO_TELEMETRY"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: disabledKey)
    }

    /// Generates an anonymous 16-hex-char identifier that rotates every calendar month.
    public static func monthlyAnonymousID(seed: String, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        let digest = SHA256.hash(data: Data("\(seed)-\(formatter.string(from: now))".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func checkIfDue(platform: String, now: Date = .now) async -> Status? {
        guard !isDisabled else { return nil }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastCheckKey)
        if last > 0, now.timeIntervalSince1970 - last < intervalSeconds { return nil }
        let seed: String
        if let existing = defaults.string(forKey: installSeedKey), !existing.isEmpty {
            seed = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: installSeedKey)
            seed = created
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "v", value: version),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "arch", value: arch),
            URLQueryItem(name: "id", value: monthlyAnonymousID(seed: seed, now: now)),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            defaults.set(now.timeIntervalSince1970, forKey: lastCheckKey)
            return try? JSONDecoder().decode(Status.self, from: data)
        } catch {
            return nil
        }
    }
}
