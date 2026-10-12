import Foundation
import Security

public enum ApprovalAction: String, Codable, Sendable {
    case fill
    case acquire
}

public enum ApprovalChoice: String, Codable, CaseIterable, Sendable {
    case approve
    case deny
    case blockThisLogin
}

public struct HarnessProcessStartTime: Codable, Equatable, Hashable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public struct HarnessSession: Codable, Equatable, Hashable, Sendable {
    public let processIdentifier: Int32
    public let processStartTime: HarnessProcessStartTime

    public init(processIdentifier: Int32, processStartTime: HarnessProcessStartTime) {
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
    }
}

public struct ApprovalRequesterContext: Codable, Equatable, Sendable {
    public let session: HarnessSession?
    public let workingDirectory: String?

    public init(session: HarnessSession?, workingDirectory: String?) {
        self.session = session
        self.workingDirectory = workingDirectory
    }
}

public struct ApprovalRequest: Equatable, Sendable {
    public static let lifetimeSeconds: TimeInterval = 10 * 60
    public let id: UUID
    public let agentDisplayLabel: String
    public let requesterContext: ApprovalRequesterContext?
    public let site: String
    public let account: String
    public let field: AgentCredentialField
    public let action: ApprovalAction
    public let oneTimeValue: Data
    public let createdAt: Date
    public let expiresAt: Int64

    public init(id: UUID = UUID(), agentDisplayLabel: String, site: String, account: String,
        field: AgentCredentialField, action: ApprovalAction, requesterContext: ApprovalRequesterContext? = nil, createdAt: Date = Date()) throws {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        self.id = id
        self.agentDisplayLabel = agentDisplayLabel
        self.requesterContext = requesterContext
        self.site = site
        self.account = account
        self.field = field
        self.action = action
        self.oneTimeValue = Data(randomBytes)
        self.createdAt = createdAt
        self.expiresAt = Int64(floor(createdAt.timeIntervalSince1970 + Self.lifetimeSeconds))
    }

    public var signedFields: ApprovalSignedFields {
        ApprovalSignedFields(requestID: id, agentDisplayLabel: agentDisplayLabel, site: site, account: account, field: field,
            action: action, oneTimeValue: oneTimeValue, expiresAt: expiresAt, requesterContext: requesterContext)
    }
}

/// Fields sent for approval. The Mac signs and verifies only its retained copy.
public struct ApprovalSignedFields: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let agentDisplayLabel: String
    public let requesterContext: ApprovalRequesterContext?
    public let site: String
    public let account: String
    public let field: AgentCredentialField
    public let action: ApprovalAction
    public let oneTimeValue: Data
    public let expiresAt: Int64

    public init(requestID: UUID, agentDisplayLabel: String, site: String, account: String, field: AgentCredentialField,
        action: ApprovalAction, oneTimeValue: Data, expiresAt: Int64, requesterContext: ApprovalRequesterContext? = nil) {
        self.requestID = requestID
        self.agentDisplayLabel = agentDisplayLabel
        self.requesterContext = requesterContext
        self.site = site
        self.account = account
        self.field = field
        self.action = action
        self.oneTimeValue = oneTimeValue
        self.expiresAt = expiresAt
    }

    public var notificationTitle: String { "\(agentDisplayLabel) wants your \(field.rawValue)" }
    public var notificationBody: String {
        let login = "\(site) · \(account)"
        guard let requesterContext else { return login }
        return [login, requesterContext.workingDirectory].compactMap { $0 }.joined(separator: "\n")
    }
    public var notificationSubtitle: String { action.rawValue }

    /// v1: domain prefix, UUID bytes, length-prefixed UTF-8 agent label/site/account/field/action,
    /// length-prefixed nonce, Int64 Unix expiry seconds, length-prefixed choice.
    /// v3 adds the harness session and working directory before the nonce.
    /// All lengths are UInt32 and all numbers are big-endian. Strings are used verbatim.
    /// ApprovalRecordsTests.canonicalEncoding fixes the complete wire format with a byte vector.
    public func canonicalBytes(for choice: ApprovalChoice) -> Data {
        var bytes = Data((requesterContext == nil ? "AgentKeyring.approval.v1\0" : "AgentKeyring.approval.v3\0").utf8)
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
        if let requesterContext {
            bytes.append(requesterContext.session == nil ? 0 : 1)
            if let session = requesterContext.session {
                var pid = session.processIdentifier.bigEndian
                var seconds = session.processStartTime.seconds.bigEndian
                var microseconds = session.processStartTime.microseconds.bigEndian
                withUnsafeBytes(of: &pid) { bytes.append(contentsOf: $0) }
                withUnsafeBytes(of: &seconds) { bytes.append(contentsOf: $0) }
                withUnsafeBytes(of: &microseconds) { bytes.append(contentsOf: $0) }
            }
            appendLengthPrefixed(Data((requesterContext.workingDirectory ?? "").utf8))
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
