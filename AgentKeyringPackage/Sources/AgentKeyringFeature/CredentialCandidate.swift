import Foundation

public struct CredentialCandidate: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let username: String?
    public let origins: [String]
    public let availableFields: [AgentCredentialField]
    public let possiblyStale: Bool?
    public var isPossiblyStale: Bool { possiblyStale == true }
    /// When Passwords last changed it, if it said: how a later copy tells what changed.
    public let lastModifiedAt: Date?

    public init(
        id: UUID,
        title: String,
        username: String?,
        origins: [String],
        availableFields: [AgentCredentialField],
        possiblyStale: Bool? = nil,
        lastModifiedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.origins = origins
        self.availableFields = availableFields
        self.possiblyStale = possiblyStale
        self.lastModifiedAt = lastModifiedAt
    }
}

extension MirrorItem {
    /// What an agent and the screens may see of a login: never a secret.
    var candidate: CredentialCandidate {
        let passwords = credentials.filter { if case .password = $0 { true } else { false } }
        let codes = credentials.filter { if case .totp = $0 { true } else { false } }
        var fields = [AgentCredentialField]()
        if let accountName, !accountName.isEmpty { fields.append(.username) }
        if passwords.count == 1 { fields.append(.password) }
        if codes.count == 1 { fields.append(.totp) }
        return CredentialCandidate(id: id, title: title, username: accountName, origins: origins, availableFields: fields,
            lastModifiedAt: lastModifiedAt)
    }
}
