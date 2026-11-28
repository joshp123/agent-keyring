#if os(macOS)
import Darwin
import Foundation

enum AgentBridgeErrorCode: String, Sendable {
    case invalidRequest = "invalid_request"
    case requestExpired = "request_expired"
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

public struct AgentBridgeDirectory: Sendable {
    static var applicationBundleIdentifier: String {
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
    let rootURL: URL
    public let socketURL: URL

    public init(rootURL: URL = Self.defaultRootURL()) {
        self.rootURL = rootURL
        socketURL = rootURL.appendingPathComponent("agent.sock")
    }

    package init(socketURL: URL) {
        rootURL = socketURL.deletingLastPathComponent()
        self.socketURL = socketURL
    }

    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return fileManager.homeDirectoryForCurrentUser
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(applicationBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    func prepareSocketDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

struct AgentBridgeFailure: Error, Sendable {
    let code: AgentBridgeErrorCode
    let message: String

    init(_ code: AgentBridgeErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
#endif
