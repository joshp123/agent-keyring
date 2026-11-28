// Written by AI on 2026.11.25 by model gemini-4-neon.
//
// Builds a single-item LoginImportBatch from the manual "Add a password" sheet
// so manual entries flow through the exact same VaultSnapshotMerger, sealing and
// CloudKit pipeline as Apple Passwords imports.

import CryptoKit
import Foundation

public enum ManualCredentialError: Error, Equatable, LocalizedError, Sendable {
    case missingWebsite
    case missingPassword
    case invalidTwoFactorKey

    public var errorDescription: String? {
        switch self {
        case .missingWebsite:
            "Enter a website address, such as cloudflare.com."
        case .missingPassword:
            "Enter a password."
        case .invalidTwoFactorKey:
            "That two-factor key isn’t a valid setup key."
        }
    }
}

public enum ManualCredentialBuilder {
    static let sourceIdentifier = "agent-keyring.manual"

    /// Validates and normalises a manual entry into a `LoginImportBatch` with `.selected` scope.
    public static func buildBatch(
        website: String,
        account: String,
        password: String,
        totpSecret: String? = nil,
        now: Date = .now
    ) throws -> LoginImportBatch {
        let trimmedSite = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSite.isEmpty else { throw ManualCredentialError.missingWebsite }

        guard !password.isEmpty else { throw ManualCredentialError.missingPassword }

        let (origin, host) = try normaliseWebsite(trimmedSite)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName: String? = trimmedAccount.isEmpty ? nil : trimmedAccount

        var credentials: [ImportedLoginSecret] = [
            .password(userName: userName, password: password)
        ]

        let trimmedTOTP = (totpSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTOTP.isEmpty {
            let parsed = try parseTwoFactorKey(trimmedTOTP, account: userName, issuer: host)
            credentials.append(parsed)
        }

        // Stable source identity per (host, account) so re-adding updates cleanly.
        let identityKey = "\(host.lowercased())\u{1F}\(trimmedAccount.lowercased())"
        let itemID = Data(SHA256.hash(data: Data(identityKey.utf8)).prefix(16))

        let item = StoredVaultLogin(
            id: UUID(),
            sourceIdentity: LoginSourceIdentity(
                exporterIdentifier: sourceIdentifier,
                accountID: Data("manual".utf8),
                itemID: itemID
            ),
            // Nil createdAt keeps LoginIdentity deterministic across re-adds for the same (host, account).
            createdAt: nil,
            lastModifiedAt: now,
            title: host,
            subtitle: userName,
            isFavorite: false,
            origins: [origin],
            credentials: credentials
        )

        return LoginImportBatch(
            scope: .selected,
            exportedAt: now,
            exporterIdentifier: sourceIdentifier,
            exporterDisplayName: "Manual entry",
            items: [item],
            skippedCredentialCount: 0
        )
    }

    static func normaliseWebsite(_ raw: String) throws -> (origin: String, host: String) {
        let hasScheme = raw.contains("://")
        let candidate = hasScheme ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host.contains(".")
        else {
            throw ManualCredentialError.missingWebsite
        }
        let scheme = (components.scheme?.lowercased() == "http") ? "http" : "https"
        let port = components.port.map { ":\($0)" } ?? ""
        return ("\(scheme)://\(host)\(port)", host)
    }

    /// Parses either a raw Base32 secret (spaces/hyphens ignored) or an `otpauth://totp/...` URI.
    static func parseTwoFactorKey(
        _ raw: String,
        account: String?,
        issuer: String?
    ) throws -> ImportedLoginSecret {
        var secretText = raw
        var period: UInt16 = 30
        var digits: UInt16 = 6
        var algorithm: OneTimeCodeAlgorithm = .sha1
        var parsedIssuer = issuer

        if raw.lowercased().hasPrefix("otpauth://") {
            guard let components = URLComponents(string: raw),
                  components.host?.lowercased() == "totp",
                  let items = components.queryItems,
                  let secretItem = items.first(where: { $0.name.lowercased() == "secret" })?.value,
                  !secretItem.isEmpty
            else {
                throw ManualCredentialError.invalidTwoFactorKey
            }
            secretText = secretItem
            if let rawPeriod = items.first(where: { $0.name.lowercased() == "period" })?.value {
                guard let p = UInt16(rawPeriod), p > 0 else { throw ManualCredentialError.invalidTwoFactorKey }
                period = p
            }
            if let rawDigits = items.first(where: { $0.name.lowercased() == "digits" })?.value {
                guard let d = UInt16(rawDigits), (6...8).contains(d) else { throw ManualCredentialError.invalidTwoFactorKey }
                digits = d
            }
            if let a = items.first(where: { $0.name.lowercased() == "algorithm" })?.value?.lowercased() {
                switch a {
                case "sha1": algorithm = .sha1
                case "sha256": algorithm = .sha256
                case "sha512": algorithm = .sha512
                default: throw ManualCredentialError.invalidTwoFactorKey
                }
            }
            if let iss = items.first(where: { $0.name.lowercased() == "issuer" })?.value, !iss.isEmpty {
                parsedIssuer = iss
            }
        }

        guard let secret = decodeBase32(secretText), !secret.isEmpty else {
            throw ManualCredentialError.invalidTwoFactorKey
        }
        return .totp(
            secret: secret,
            period: period,
            digits: digits,
            userName: account,
            algorithm: algorithm,
            issuer: parsedIssuer
        )
    }

    static func decodeBase32(_ input: String) -> Data? {
        let cleaned = input
            .uppercased()
            .filter { $0 != " " && $0 != "-" && $0 != "\t" && $0 != "\n" && $0 != "\r" }
        guard !cleaned.isEmpty else { return nil }
        let stripped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard !stripped.isEmpty else { return nil }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (i, ch) in alphabet.enumerated() { lookup[ch] = UInt8(i) }

        var buffer: UInt32 = 0
        var bitsLeft = 0
        var output = Data()
        for ch in stripped {
            guard let val = lookup[ch] else { return nil }
            buffer = (buffer << 5) | UInt32(val)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                output.append(UInt8((buffer >> bitsLeft) & 0xFF))
            }
        }
        return output.isEmpty ? nil : output
    }
}
