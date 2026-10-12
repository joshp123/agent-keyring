import AppKit
import Foundation
import LocalAuthentication
import OSLog

private let credentialAuthorizationLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "CredentialAuthorization"
)

public struct CredentialReleaseAuthorizationRequest: Equatable, Sendable {
    public let destination: String
    public let account: String
    public let field: AgentCredentialField
    public let credentialTitle: String
    public let fillsFocusedField: Bool
    public let expirationSeconds: Int?
    public let authorizationDeadline: Date
    public let isPossiblyStale: Bool

    public init(
        destination: String,
        account: String,
        field: AgentCredentialField,
        credentialTitle: String? = nil,
        expirationSeconds: Int? = 30,
        fillsFocusedField: Bool = false,
        authorizationDeadline: Date = Date().addingTimeInterval(AgentBridgeRequest.lifetimeSeconds),
        isPossiblyStale: Bool = false
    ) {
        self.destination = destination
        self.account = account
        self.field = field
        self.credentialTitle = credentialTitle ?? account
        self.fillsFocusedField = fillsFocusedField
        self.expirationSeconds = expirationSeconds
        self.authorizationDeadline = authorizationDeadline
        self.isPossiblyStale = isPossiblyStale
    }

    public var localizedReason: String {
        let value =
            switch field {
            case .username: "username"
            case .password: "password"
            case .totp: "verification code"
            }
        if fillsFocusedField { return "fill the \(value) for \(account) on \(destination)" }
        return "release the \(value) for \(account) to a local agent for \(destination)"
            + (isPossiblyStale ? ". This login may be stale; update the copy from Apple Passwords." : "")
    }
}

public enum CredentialReleaseAuthorizationError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case denied
    case interrupted
    case notVerified
    case expired
    case systemFailure(domain: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Touch ID or Apple Watch approval is not available."
        case .denied:
            "Josh declined the request."
        case .interrupted:
            "macOS interrupted the approval prompt; retry the request."
        case .notVerified:
            "Touch ID or Apple Watch did not verify; retry the request."
        case .expired:
            "The request expired with no answer."
        case let .systemFailure(domain, code):
            "Credential approval failed (\(domain == LAError.errorDomain ? "LocalAuthentication" : domain) \(code)). Nothing was released."
        }
    }

    static func classifyNativeFailure(
        _ error: NSError, authorizationDeadline: Date, now: Date = Date()
    ) -> Self {
        guard authorizationDeadline > now else { return .expired }
        if error.domain == LAError.errorDomain, let code = LAError.Code(rawValue: error.code) {
            switch code {
            case .authenticationFailed, .biometryLockout:
                return .notVerified
            case .userCancel:
                return .denied
            case .systemCancel:
                return .interrupted
            case .biometryNotAvailable, .companionNotAvailable, .notInteractive:
                return .unavailable
            default:
                break
            }
        }
        return .systemFailure(domain: error.domain, code: error.code)
    }
}

@MainActor
public protocol CredentialReleaseAuthorizing {
    func authorize(_ request: CredentialReleaseAuthorizationRequest, onPromptStarted: @escaping () -> Void) async throws
    func cancelCurrentAuthorization()
}

public extension CredentialReleaseAuthorizing {
    func cancelCurrentAuthorization() {}
}

@MainActor
public final class LocalCredentialReleaseAuthorizer: CredentialReleaseAuthorizing {
    private var activeContext: LAContext?

    public init() {}

    public func authorize(_ request: CredentialReleaseAuthorizationRequest, onPromptStarted: @escaping () -> Void) async throws {
        guard request.authorizationDeadline > Date() else {
            throw CredentialReleaseAuthorizationError.expired
        }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "Don't allow"
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometricsOrCompanion
        var evaluationError: NSError?

        guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
            if let evaluationError {
                credentialAuthorizationLogger.error(
                    "Approval preflight failed: domain=\(evaluationError.domain, privacy: .public) code=\(evaluationError.code, privacy: .public)"
                )
                throw CredentialReleaseAuthorizationError.classifyNativeFailure(
                    evaluationError, authorizationDeadline: request.authorizationDeadline)
            } else {
                credentialAuthorizationLogger.error("Approval preflight failed without an error code")
            }
            throw CredentialReleaseAuthorizationError.unavailable
        }

        activeContext = context
        let remaining = request.authorizationDeadline.timeIntervalSinceNow
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining)))
            guard !Task.isCancelled, self?.activeContext === context else { return }
            context.invalidate()
        }
        defer {
            timeoutTask.cancel()
            if activeContext === context { activeContext = nil }
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        do {
            onPromptStarted()
            guard
                try await context.evaluatePolicy(
                    policy,
                    localizedReason: request.localizedReason
                )
            else {
                throw CredentialReleaseAuthorizationError.notVerified
            }
        } catch let error as CredentialReleaseAuthorizationError {
            throw error
        } catch {
            let nsError = error as NSError
            credentialAuthorizationLogger.error(
                "Approval evaluation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
            throw CredentialReleaseAuthorizationError.classifyNativeFailure(
                nsError, authorizationDeadline: request.authorizationDeadline
            )
        }
    }

    public func cancelCurrentAuthorization() {
        activeContext?.invalidate()
    }
}

extension AgentCredentialField {
    var requiresUserApproval: Bool {
        switch self {
        case .username: false
        case .password, .totp: true
        }
    }

    var approvalDisplayName: String {
        switch self {
        case .username: "Username"
        case .password: "Password"
        case .totp: "Verification code"
        }
    }

    var approvalSymbol: String {
        switch self {
        case .username: "person.text.rectangle"
        case .password: "key.fill"
        case .totp: "number.square.fill"
        }
    }
}
