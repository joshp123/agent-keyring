import AppKit
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import OSLog

private let credentialAuthorizationLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "CredentialAuthorization"
)

public struct CredentialReleaseAuthorizationRequest: Equatable, Sendable {
    public let leaseDescription: String?
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
        isPossiblyStale: Bool = false,
        leaseDescription: String? = nil
    ) {
        self.leaseDescription = leaseDescription
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
        if let leaseDescription { return leaseDescription }
        let value =
            switch field {
            case .username: "username"
            case .password: "password"
            case .totp: "verification code"
            }
        if fillsFocusedField { return "let an agent fill in your \(value) for \(account) on \(destination)" }
        return "let an agent see your \(value) for \(account) on \(destination)"
            + (isPossiblyStale ? ". This copy may be out of date; import again from Apple Passwords" : "")
    }

    /// Our words in macOS's dialog, after "Agent Keyring is trying to". The
    /// machine is named only when it is not this Mac.
    static func leaseReason(site: String, account: String, agent: String, machine: String? = nil) -> String {
        let site = URL(string: site)?.host() ?? site
        let who = (agent.isEmpty ? "an agent" : agent) + (machine.map { " on \($0)" } ?? "")
        return "let \(who) use your \(site) login, \(account)"
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
            "Approval isn't available. Check Touch ID or Apple Watch, then try again."
        case .denied:
            "\(MacOwner.firstName) declined the request."
        case .interrupted:
            "Approval was interrupted. Try again."
        case .notVerified:
            "Approval didn't confirm. Try again."
        case .expired:
            "The request expired with no answer."
        case let .systemFailure(domain, code):
            "Credential approval failed (\(domain == LAError.errorDomain ? "LocalAuthentication" : domain) \(code)). Nothing was released."
        }
    }

    /// Cancel or Escape in macOS's dialog, or the app closing it: not an answer.
    public var isCancel: Bool {
        switch self {
        case .denied, .interrupted: true
        case let .systemFailure(domain, code): domain == LAError.errorDomain && code == LAError.Code.appCancel.rawValue
        default: false
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

    /// Touch ID or the Watch. The test build's "TouchIDOnly" setting leaves
    /// the Watch out, so a rehearsal at night doesn't buzz it.
    public static var policy: LAPolicy {
        UserDefaults.standard.bool(forKey: "TouchIDOnly") ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthenticationWithBiometricsOrCompanion
    }

    public init() {}

    /// macOS's dialog appears only after Josh clicks Approve in a panel, which
    /// passes its context; nothing may ask him unprompted.
    public func authorize(_ request: CredentialReleaseAuthorizationRequest, onPromptStarted: @escaping () -> Void) async throws {
        throw CredentialReleaseAuthorizationError.unavailable
    }

    public func authorize(_ request: CredentialReleaseAuthorizationRequest, context: LAContext,
        onPromptStarted: @escaping () -> Void) async throws {
        try await evaluate(request, context: context, onPromptStarted: onPromptStarted)
    }

    private func evaluate(_ request: CredentialReleaseAuthorizationRequest, context: LAContext,
        onPromptStarted: @escaping () -> Void) async throws {
        try Task.checkCancellation()
        guard request.authorizationDeadline > Date() else {
            throw CredentialReleaseAuthorizationError.expired
        }
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "Cancel"
        let policy = Self.policy
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
        let cancelEvaluation: @MainActor @Sendable () -> Void = { context.invalidate() }
        do {
            onPromptStarted()
            let confirmed = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await context.evaluatePolicy(policy, localizedReason: request.localizedReason)
            } onCancel: {
                Task { @MainActor in cancelEvaluation() }
            }
            try Task.checkCancellation()
            guard confirmed else {
                throw CredentialReleaseAuthorizationError.notVerified
            }
        } catch let error as CredentialReleaseAuthorizationError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
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
