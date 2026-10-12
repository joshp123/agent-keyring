import Foundation

public enum AgentCredentialField: String, Codable, CaseIterable, Sendable {
    case username
    case password
    case totp
}

public struct CredentialCandidate: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let username: String?
    public let origins: [String]
    public let availableFields: [AgentCredentialField]

    public init(
        id: UUID,
        title: String,
        username: String?,
        origins: [String],
        availableFields: [AgentCredentialField]
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.origins = origins
        self.availableFields = availableFields
    }
}

public enum CredentialResolverError: String, Error, Codable, LocalizedError, Sendable {
    case invalidURL = "invalid_url"
    case insecureOrigin = "insecure_origin"
    case notFound = "not_found"
    case ambiguous = "ambiguous"
    case fieldUnavailable = "field_unavailable"
    case invalidTOTP = "invalid_totp"

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The target must be a valid URL with a host."
        case .insecureOrigin:
            "Secrets can only be copied for HTTPS pages or localhost."
        case .notFound:
            "No mirrored credential matches this site."
        case .ambiguous:
            "More than one mirrored credential matches this site."
        case .fieldUnavailable:
            "The selected credential does not have one unambiguous value for that field."
        case .invalidTOTP:
            "The selected verification-code record is invalid."
        }
    }
}

public struct CredentialResolver: Sendable {
    private struct RankedItem {
        let item: MirrorItem
        let score: Int
    }

    public init() {}

    func validateSecureTarget(_ targetURL: String) throws {
        guard try parsedTarget(targetURL).isSecure else {
            throw CredentialResolverError.insecureOrigin
        }
    }

    public func candidates(
        in generation: MirrorGeneration,
        targetURL: String,
        usernameHint: String? = nil
    ) throws -> [CredentialCandidate] {
        let target = try parsedTarget(targetURL)
        let ranked = generation.items.compactMap { item -> RankedItem? in
            if let usernameHint = normalisedUsername(usernameHint),
                normalisedUsername(item.accountName) != usernameHint {
                return nil
            }
            guard let score = bestScore(for: item.origins, target: target) else {
                return nil
            }
            return RankedItem(item: item, score: score)
        }

        guard let bestScore = ranked.map(\.score).max() else { return [] }
        let matches = ranked.filter { $0.score == bestScore }

        return
            matches
            .map { candidate(for: $0.item) }
            .filter { !$0.availableFields.isEmpty }
            .sorted {
                let lhs = ($0.title.lowercased(), $0.username?.lowercased() ?? "", $0.id.uuidString)
                let rhs = ($1.title.lowercased(), $1.username?.lowercased() ?? "", $1.id.uuidString)
                return lhs < rhs
            }
    }

    func secret(
        in generation: MirrorGeneration,
        targetURL: String,
        usernameHint: String? = nil,
        candidateID: UUID? = nil,
        field: AgentCredentialField,
        now: Date = Date()
    ) throws -> String {
        let target = try parsedTarget(targetURL)
        guard target.isSecure else { throw CredentialResolverError.insecureOrigin }

        let candidates = try candidates(
            in: generation,
            targetURL: targetURL,
            usernameHint: usernameHint
        )
        let selected: CredentialCandidate
        if let candidateID {
            guard let candidate = candidates.first(where: { $0.id == candidateID }) else {
                throw CredentialResolverError.notFound
            }
            selected = candidate
        } else {
            guard !candidates.isEmpty else { throw CredentialResolverError.notFound }
            guard candidates.count == 1 else { throw CredentialResolverError.ambiguous }
            selected = candidates[0]
        }

        guard selected.availableFields.contains(field),
            let item = generation.items.first(where: { $0.id == selected.id })
        else {
            throw CredentialResolverError.fieldUnavailable
        }

        switch field {
        case .username:
            guard let username = item.accountName,
                !username.isEmpty
            else {
                throw CredentialResolverError.fieldUnavailable
            }
            return username
        case .password:
            guard let password = uniquePassword(in: item)?.password else {
                throw CredentialResolverError.fieldUnavailable
            }
            return password
        case .totp:
            guard let record = uniqueTOTP(in: item) else {
                throw CredentialResolverError.fieldUnavailable
            }
            do {
                return try TOTPGenerator().code(
                    secret: record.secret,
                    period: record.period,
                    digits: record.digits,
                    algorithm: record.algorithm,
                    at: now
                )
            } catch {
                throw CredentialResolverError.invalidTOTP
            }
        }
    }

    private func candidate(for item: MirrorItem) -> CredentialCandidate {
        let password = uniquePassword(in: item)
        let totp = uniqueTOTP(in: item)
        var fields = [AgentCredentialField]()
        if let username = item.accountName, !username.isEmpty { fields.append(.username) }
        if password != nil { fields.append(.password) }
        if totp != nil { fields.append(.totp) }

        return CredentialCandidate(
            id: item.id,
            title: item.title,
            username: item.accountName,
            origins: item.origins,
            availableFields: fields
        )
    }

    private func uniquePassword(in item: MirrorItem) -> (userName: String?, password: String)? {
        let passwords = item.credentials.compactMap { credential -> (String?, String)? in
            guard case let .password(userName, password) = credential else { return nil }
            return (userName, password)
        }
        guard passwords.count == 1 else { return nil }
        return passwords[0]
    }

    private func uniqueTOTP(in item: MirrorItem) -> (
        secret: Data,
        period: UInt16,
        digits: UInt16,
        algorithm: MirrorTOTPAlgorithm
    )? {
        let records = item.credentials.compactMap {
            credential -> (
                Data, UInt16, UInt16, MirrorTOTPAlgorithm
            )? in
            guard case let .totp(secret, period, digits, _, algorithm, _) = credential else {
                return nil
            }
            return (secret, period, digits, algorithm)
        }
        guard records.count == 1 else { return nil }
        return records[0]
    }

    private struct ParsedTarget {
        let host: String
        let scheme: String
        let port: Int
        let isSecure: Bool
    }

    private func parsedTarget(_ value: String) throws -> ParsedTarget {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            let host = components.url?.host?.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: ".")),
            !host.isEmpty,
            scheme == "https" || scheme == "http"
        else {
            throw CredentialResolverError.invalidURL
        }
        let localhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        return ParsedTarget(
            host: host,
            scheme: scheme,
            port: components.port ?? (scheme == "https" ? 443 : 80),
            isSecure: scheme == "https" || localhost
        )
    }

    private func bestScore(for origins: [String], target: ParsedTarget) -> Int? {
        origins.compactMap { origin -> Int? in
            guard let parsed = try? parsedTarget(origin) else { return nil }
            let upgradesDefaultHTTP = parsed.scheme == "http" && parsed.port == 80
                && target.scheme == "https" && target.port == 443
            if parsed.port != target.port && !upgradesDefaultHTTP {
                return nil
            }
            return hostScore(stored: parsed.host, target: target.host)
        }.max()
    }

    private func hostScore(stored: String, target: String) -> Int? {
        if stored == target { return 300 }
        if target.hasSuffix(".\(stored)") { return 200 }
        return nil
    }

    private func normalisedUsername(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value.lowercased()
    }
}
