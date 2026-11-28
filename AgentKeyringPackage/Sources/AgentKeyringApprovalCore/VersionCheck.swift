// Written by AI on 2026.11.23 by model gemini-4-neon.
//
// Zero-PII daily version check against https://push.opentrawl.sh/v1/version.
// Sends only app version, platform, CPU architecture, and one stable, anonymous,
// non-reversible SHA-256 hash (no IP stored server-side, no names, Apple IDs,
// usernames, sites, or passwords).
// Opt out via Settings/Devices ("no_telemetry") or AGENT_KEYRING_NO_TELEMETRY=1.

import CryptoKit
import Foundation

public struct VersionCheckStatus: Sendable, Decodable {
    public let latest: String
    public let url: String
    public let testflight: String?
}

public enum VersionCheck {

    public static let endpoint = URL(string: "https://push.opentrawl.sh/v1/version")!
    public static let noTelemetryKey = "no_telemetry"
    private static let lastCheckKey = "lastVersionCheckUnix"
    private static let installSeedKey = "versionCheckSeed"
    private static let accountHashKey = "versionCheckAccountHash"
    private static let intervalSeconds: TimeInterval = 24 * 60 * 60

    public static func isTruthyEnvFlag(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    public static var isDisabled: Bool {
        if isTruthyEnvFlag(ProcessInfo.processInfo.environment["AGENT_KEYRING_NO_TELEMETRY"]) { return true }
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: noTelemetryKey)
    }

    public static func setNoTelemetry(_ disabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(disabled, forKey: noTelemetryKey)
    }

    /// Generates one stable, anonymous, non-reversible 16-hex-char identifier.
    /// Uses the app-scoped iCloud user record ID when available so one person's
    /// Mac and iPhone count as one user; falls back to a random local install seed.
    public static func anonymousID(accountSeed: String? = nil, localSeed: String) -> String {
        let source: String
        if let account = accountSeed?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
            source = "agent-keyring:account:\(account)"
        } else {
            source = "agent-keyring:install:\(localSeed)"
        }
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolves the current anonymous identifier, caching only the hashed iCloud ID
    /// so temporary offline periods keep the same user identifier.
    public static func resolvedAnonymousID(accountSeed: String? = nil, defaults: UserDefaults = .standard) -> String {
        if let account = accountSeed?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
            let hashed = anonymousID(accountSeed: account, localSeed: "")
            defaults.set(hashed, forKey: accountHashKey)
            return hashed
        }
        if let cached = defaults.string(forKey: accountHashKey), !cached.isEmpty {
            return cached
        }
        let seed: String
        if let existing = defaults.string(forKey: installSeedKey), !existing.isEmpty {
            seed = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: installSeedKey)
            seed = created
        }
        return anonymousID(accountSeed: nil, localSeed: seed)
    }

    @discardableResult
    public static func checkIfDue(platform: String, accountSeed: String? = nil, now: Date = .now) async -> VersionCheckStatus? {
        guard !isDisabled else { return nil }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastCheckKey)
        if last > 0, now.timeIntervalSince1970 - last < intervalSeconds { return nil }
        let anonID = resolvedAnonymousID(accountSeed: accountSeed, defaults: defaults)
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
            URLQueryItem(name: "id", value: anonID),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            defaults.set(now.timeIntervalSince1970, forKey: lastCheckKey)
            return try? JSONDecoder().decode(VersionCheckStatus.self, from: data)
        } catch {
            return nil
        }
    }
}
