import Darwin
import Foundation

public enum AgentBridgeAction: String, Codable, Sendable {
    case status
    case acquire
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
    case internalError = "internal_error"
}

public struct AgentBridgeRequest: Codable, Equatable, Sendable {
    public static let lifetimeSeconds: TimeInterval = 10 * 60
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public let callerPID: Int32
    public let action: AgentBridgeAction
    public let targetURL: String?
    public let usernameHint: String?
    public let candidateID: UUID?
    public let field: AgentCredentialField?
    public let expirationSeconds: Int

    public var expiresAt: Date { createdAt.addingTimeInterval(Self.lifetimeSeconds) }

    public init(
        version: Int = 1,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        callerPID: Int32 = getpid(),
        action: AgentBridgeAction,
        targetURL: String? = nil,
        usernameHint: String? = nil,
        candidateID: UUID? = nil,
        field: AgentCredentialField? = nil,
        expirationSeconds: Int = 30
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.callerPID = callerPID
        self.action = action
        self.targetURL = targetURL
        self.usernameHint = usernameHint
        self.candidateID = candidateID
        self.field = field
        self.expirationSeconds = expirationSeconds
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

public struct AgentApprovalProgress: Codable, Equatable, Sendable {
    public let waitingSince: Date
    public let askedAt: Date?
    public let phase: AgentApprovalPhase

    public init(waitingSince: Date, askedAt: Date? = nil, phase: AgentApprovalPhase) {
        self.waitingSince = waitingSince
        self.askedAt = askedAt
        self.phase = phase
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
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
            bundleIdentifier.hasSuffix(".AgentKeyring"),
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        {
            return
                applicationSupport
                .appendingPathComponent("AgentKeyring", isDirectory: true)
                .appendingPathComponent("agent-bridge", isDirectory: true)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(applicationBundleIdentifier, isDirectory: true)
            .appendingPathComponent(
                "Data/Library/Application Support/AgentKeyring/agent-bridge", isDirectory: true)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    public func write(_ request: AgentBridgeRequest) throws {
        try prepare()
        try secureWrite(try encoder.encode(request), to: requestURL(for: request.id))
    }

    public func readRequest(id: UUID) throws -> AgentBridgeRequest {
        let url = requestURL(for: id)
        try validateOwnedRegularFile(url)
        return try decoder.decode(AgentBridgeRequest.self, from: Data(contentsOf: url))
    }

    public func removeRequest(id: UUID) {
        try? FileManager.default.removeItem(at: requestURL(for: id))
    }

    public func write(_ response: AgentBridgeResponse) throws {
        try prepare()
        try secureWrite(try encoder.encode(response), to: responseURL(for: response.id))
    }

    public func readResponse(id: UUID) throws -> AgentBridgeResponse {
        let url = responseURL(for: id)
        try validateOwnedRegularFile(url)
        return try decoder.decode(AgentBridgeResponse.self, from: Data(contentsOf: url))
    }

    public func write(_ progress: AgentApprovalProgress, id: UUID) throws {
        try prepare()
        try secureWrite(try encoder.encode(progress), to: progressURL(for: id))
    }

    public func readProgress(id: UUID) throws -> AgentApprovalProgress {
        let url = progressURL(for: id)
        try validateOwnedRegularFile(url)
        return try decoder.decode(AgentApprovalProgress.self, from: Data(contentsOf: url))
    }

    public func removeProgress(id: UUID) {
        try? FileManager.default.removeItem(at: progressURL(for: id))
    }

    public func removeResponse(id: UUID) {
        try? FileManager.default.removeItem(at: responseURL(for: id))
    }

    public func responseExists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: responseURL(for: id).path)
    }

    public func requestMatches(_ request: AgentBridgeRequest) -> Bool {
        guard let current = try? readRequest(id: request.id) else { return false }
        return current.version == request.version
            && current.id == request.id
            && Int(current.createdAt.timeIntervalSince1970)
                == Int(request.createdAt.timeIntervalSince1970)
            && current.callerPID == request.callerPID
            && current.action == request.action
            && current.targetURL == request.targetURL
            && current.usernameHint == request.usernameHint
            && current.candidateID == request.candidateID
            && current.field == request.field
            && current.expirationSeconds == request.expirationSeconds
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func requestURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).request.json", isDirectory: false)
    }

    private func progressURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).progress.json", isDirectory: false)
    }

    private func responseURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).response.json", isDirectory: false)
    }

    private func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func validateOwnedRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let owner = attributes[.ownerAccountID] as? NSNumber,
            owner.uint32Value == getuid()
        else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
