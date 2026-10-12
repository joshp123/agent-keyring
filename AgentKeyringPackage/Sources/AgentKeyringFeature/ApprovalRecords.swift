import CryptoKit
import Foundation

public enum ApprovalAction: String, Codable, Sendable {
    case fill
    case acquire
}

public enum ApprovalChoice: String, Codable, CaseIterable, Sendable {
    case approve
    case deny
    case blockThisLogin
}

public struct ApprovalRequest: Codable, Equatable, Sendable {
    public static let lifetimeSeconds: TimeInterval = 10 * 60
    public let id: UUID
    public let agentDisplayLabel: String
    public let site: String
    public let account: String
    public let field: AgentCredentialField
    public let action: ApprovalAction
    public let oneTimeValue: Data
    public let createdAt: Date
    public let expiresAt: Int64

    public init(id: UUID = UUID(), agentDisplayLabel: String, site: String, account: String,
        field: AgentCredentialField, action: ApprovalAction, createdAt: Date = Date()) {
        self.id = id
        self.agentDisplayLabel = agentDisplayLabel
        self.site = site
        self.account = account
        self.field = field
        self.action = action
        self.oneTimeValue = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        self.createdAt = createdAt
        self.expiresAt = Int64(floor(createdAt.timeIntervalSince1970 + Self.lifetimeSeconds))
    }

    public var signedFields: ApprovalSignedFields {
        ApprovalSignedFields(requestID: id, agentDisplayLabel: agentDisplayLabel, site: site, account: account, field: field,
            action: action, oneTimeValue: oneTimeValue, expiresAt: expiresAt)
    }
}

/// Fields sent for approval. The Mac signs and verifies only its retained copy.
public struct ApprovalSignedFields: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let agentDisplayLabel: String
    public let site: String
    public let account: String
    public let field: AgentCredentialField
    public let action: ApprovalAction
    public let oneTimeValue: Data
    public let expiresAt: Int64

    public init(requestID: UUID, agentDisplayLabel: String, site: String, account: String, field: AgentCredentialField,
        action: ApprovalAction, oneTimeValue: Data, expiresAt: Int64) {
        self.requestID = requestID
        self.agentDisplayLabel = agentDisplayLabel
        self.site = site
        self.account = account
        self.field = field
        self.action = action
        self.oneTimeValue = oneTimeValue
        self.expiresAt = expiresAt
    }

    /// v1: domain prefix, UUID bytes, length-prefixed UTF-8 agent label/site/account/field/action,
    /// length-prefixed nonce, Int64 Unix expiry seconds, length-prefixed choice.
    /// All lengths are UInt32 and all numbers are big-endian. Strings are used verbatim.
    /// ApprovalRecordsTests.canonicalEncoding fixes the complete wire format with a byte vector.
    public func canonicalBytes(for choice: ApprovalChoice) -> Data {
        var bytes = Data("AgentKeyring.approval.v1\0".utf8)
        var requestUUID = requestID.uuid
        withUnsafeBytes(of: &requestUUID) { bytes.append(contentsOf: $0) }
        func appendLengthPrefixed(_ value: Data) {
            var length = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        for text in [agentDisplayLabel, site, account, field.rawValue, action.rawValue] {
            appendLengthPrefixed(Data(text.utf8))
        }
        appendLengthPrefixed(oneTimeValue)
        var expiry = expiresAt.bigEndian
        withUnsafeBytes(of: &expiry) { bytes.append(contentsOf: $0) }
        appendLengthPrefixed(Data(choice.rawValue.utf8))
        return bytes
    }
}

public struct ApprovalDecision: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let choice: ApprovalChoice
    /// P-256 X9.63 public key bytes; only a key in the verified paired-device store is trusted.
    public let devicePublicKey: Data
    /// P-256 ECDSA DER signature of the request's canonicalBytes(for: choice), using SHA-256.
    public let signature: Data

    public init(requestID: UUID, choice: ApprovalChoice, devicePublicKey: Data,
        signature: Data) {
        self.requestID = requestID
        self.choice = choice
        self.devicePublicKey = devicePublicKey
        self.signature = signature
    }
}
