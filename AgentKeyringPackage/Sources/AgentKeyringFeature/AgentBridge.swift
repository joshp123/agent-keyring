import Darwin
import Foundation

public enum AgentBridgeAction: String, Codable, Hashable, Sendable {
    case status
    case acquire
    case fill
    case resolve
    case sync
}

public enum AgentBridgeErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case requestExpired = "request_expired"
    case mirrorUnavailable = "mirror_unavailable"
    case bridgeUnavailable = "bridge_unavailable"
    case timedOut = "timed_out"
    case invalidURL = "invalid_url"
    case insecureOrigin = "insecure_origin"
    case notFound = "not_found"
    case ambiguous = "ambiguous"
    case fieldUnavailable = "field_unavailable"
    case invalidTOTP = "invalid_totp"
    case approvalPending = "approval_pending"
    case authorizationDenied = "authorization_denied"
    case authorizationNotVerified = "authorization_not_verified"
    case authorizationInterrupted = "authorization_interrupted"
    case authorizationUnavailable = "authorization_unavailable"
    case policyDenied = "policy_denied"
    case rulesNeedConfirmation = "rules_need_confirmation"
    case wrongFocusedField = "wrong_focused_field"
    case pageMismatch = "page_mismatch"
    case unsupportedBrowser = "unsupported_browser"
    case unreadablePageAddress = "unreadable_page_address"
    case accessibilityMissing = "accessibility_missing"
    case screenLocked = "screen_locked"
    case fillTargetChanged = "fill_target_changed"
    case internalError = "internal_error"
}

public struct AgentBridgeRequest: Codable, Equatable, Sendable {
    public static let lifetimeSeconds: TimeInterval = 10 * 60
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public let callerPID: Int32
    public let agentDisplayLabel: String?
    public let action: AgentBridgeAction
    public let targetURL: String?
    public let usernameHint: String?
    public let candidateID: UUID?
    public let field: AgentCredentialField?
    public let expirationSeconds: Int
    public let bufferPublicationDeadline: Date?

    public var expiresAt: Date { createdAt.addingTimeInterval(Self.lifetimeSeconds) }

    public init(
        version: Int = 1,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        callerPID: Int32 = getpid(),
        agentDisplayLabel: String = AgentDisplayLabel.parentExecutableName(),
        action: AgentBridgeAction,
        targetURL: String? = nil,
        usernameHint: String? = nil,
        candidateID: UUID? = nil,
        field: AgentCredentialField? = nil,
        expirationSeconds: Int = 30,
        bufferPublicationDeadline: Date? = nil
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.callerPID = callerPID
        self.agentDisplayLabel = agentDisplayLabel
        self.action = action
        self.targetURL = targetURL
        self.usernameHint = usernameHint
        self.candidateID = candidateID
        self.field = field
        self.expirationSeconds = expirationSeconds
        self.bufferPublicationDeadline = bufferPublicationDeadline
    }
}

public struct AgentMirrorSummary: Codable, Equatable, Sendable {
    public let importedAt: Date
    public let ageSeconds: Int
    public let credentialCount: Int

    public init(importedAt: Date, ageSeconds: Int, credentialCount: Int) {
        self.importedAt = importedAt
        self.ageSeconds = ageSeconds
        self.credentialCount = credentialCount
    }
}

public enum AgentApprovalPhase: String, Codable, Sendable {
    case waitingForUnlock
    case awaitingApproval
}

public enum ApprovalPromptProvider: String, Codable, Sendable {
    case mac
    case iPhone
}

public struct AgentApprovalProgress: Codable, Equatable, Sendable {
    public let waitingSince: Date
    public let askedAt: Date?
    public let phase: AgentApprovalPhase

    public let provider: ApprovalPromptProvider?
    public let phoneScheduledAt: Date?
    public let macWasLocked: Bool?
    public let macWasAsleep: Bool?
    public let approvedAt: Date?
    public let approvedOn: ApprovalPromptProvider?
    public let iPhoneFailure: IPhoneApprovalFailure?

    public init(waitingSince: Date, askedAt: Date? = nil, phase: AgentApprovalPhase,
        provider: ApprovalPromptProvider? = nil, phoneScheduledAt: Date? = nil,
        macWasLocked: Bool? = nil, macWasAsleep: Bool? = nil, approvedAt: Date? = nil, approvedOn: ApprovalPromptProvider? = nil,
        iPhoneFailure: IPhoneApprovalFailure? = nil) {
        self.waitingSince = waitingSince
        self.askedAt = askedAt
        self.phase = phase
        self.provider = provider
        self.phoneScheduledAt = phoneScheduledAt
        self.macWasLocked = macWasLocked
        self.macWasAsleep = macWasAsleep
        self.approvedAt = approvedAt
        self.approvedOn = approvedOn
        self.iPhoneFailure = iPhoneFailure
    }
}

public enum AgentBridgeWaitStatus: Sendable {
    case progress(AgentApprovalProgress)
    case stillWaiting(progress: AgentApprovalProgress)
}

public struct AgentBridgeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let ok: Bool
    public let error: AgentBridgeErrorCode?
    public let message: String?
    public let mirror: AgentMirrorSummary?
    public let candidates: [CredentialCandidate]?
    public let filledField: AgentCredentialField?
    public let copiedField: AgentCredentialField?
    public let clipboardExpiresAt: Date?
    public let approvalProgress: AgentApprovalProgress?

    public init(
        version: Int = 1,
        id: UUID,
        ok: Bool,
        error: AgentBridgeErrorCode? = nil,
        message: String? = nil,
        mirror: AgentMirrorSummary? = nil,
        candidates: [CredentialCandidate]? = nil,
        filledField: AgentCredentialField? = nil,
        copiedField: AgentCredentialField? = nil,
        clipboardExpiresAt: Date? = nil,
        approvalProgress: AgentApprovalProgress? = nil
    ) {
        self.version = version
        self.id = id
        self.ok = ok
        self.error = error
        self.message = message
        self.mirror = mirror
        self.candidates = candidates
        self.filledField = filledField
        self.copiedField = copiedField
        self.clipboardExpiresAt = clipboardExpiresAt
        self.approvalProgress = approvalProgress
    }
}

public struct AgentBridgeDirectory: Sendable {
    public static var applicationBundleIdentifier: String {
        let appPath = "/Applications/AgentKeyring.app"
        let infoURL = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        if let data = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any],
            let bundleID = dictionary["CFBundleIdentifier"] as? String,
            !bundleID.isEmpty
        {
            return bundleID
        }
        return "com.example.AgentKeyring"
    }
    public let rootURL: URL

    public init(rootURL: URL = Self.defaultRootURL()) {
        self.rootURL = rootURL
    }

    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        if Bundle.main.bundleIdentifier?.hasSuffix(".AgentKeyring") == true {
            return fileManager.homeDirectoryForCurrentUser
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(applicationBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public var socketURL: URL { rootURL.appendingPathComponent("agent.sock") }
}
