public enum AgentCredentialField: String, Codable, CaseIterable, Sendable {
    case username
    case password
    case totp
}
