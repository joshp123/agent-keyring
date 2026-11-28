#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import OSLog

private let credentialAuthorizationLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "CredentialAuthorization"
)

public enum CredentialReleaseAuthorizationError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case denied
    case interrupted
    case notVerified
    case expired
    case systemFailure(domain: String, code: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable: MessageCopy.approvalUnavailable
        case .denied: MessageCopy.declined(MacOwner.firstName)
        case .interrupted: MessageCopy.approvalInterrupted
        case .notVerified: MessageCopy.approvalNotConfirmed
        case .expired: MessageCopy.expired
        case .systemFailure:
            MessageCopy.approvalFailed
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
            case .biometryNotAvailable, .biometryNotPaired, .biometryDisconnected, .companionNotAvailable, .passcodeNotSet, .notInteractive:
                return .unavailable
            default:
                break
            }
        }
        return .systemFailure(domain: error.domain, code: error.code)
    }
}

/// macOS's own dialog for Touch ID or the Watch, or the Mac password on a Mac
/// that approves with it. It appears only after Josh clicks to approve; the
/// same context then opens and signs with the chip keys.
@MainActor
enum OwnerBiometricConfirmation {
    /// As this Mac's keys were made (MacApprovalMode.policy).
    static var policy: LAPolicy { MacApprovalMode.current.policy }

    static func checkDeadline(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard deadline > Date() else { throw CredentialReleaseAuthorizationError.expired }
    }

    static func confirm(_ context: LAContext, reason: String, until deadline: Date) async throws {
        try checkDeadline(deadline)
        MacApprovalMode.current.prepareAuthenticationContext(context)
        context.localizedCancelTitle = "Cancel"
        var preflight: NSError?
        guard context.canEvaluatePolicy(policy, error: &preflight) else {
            if let preflight {
                credentialAuthorizationLogger.error("Approval preflight failed: domain=\(preflight.domain, privacy: .public) code=\(preflight.code, privacy: .public)")
                throw CredentialReleaseAuthorizationError.classifyNativeFailure(preflight, authorizationDeadline: deadline)
            }
            throw CredentialReleaseAuthorizationError.unavailable
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            if !Task.isCancelled { context.invalidate() }
        }
        defer { timeout.cancel() }
        let cancelEvaluation: @MainActor @Sendable () -> Void = { context.invalidate() }
        do {
            let confirmed = try await withTaskCancellationHandler {
                try await context.evaluatePolicy(policy, localizedReason: reason)
            } onCancel: { Task { @MainActor in cancelEvaluation() } }
            try Task.checkCancellation()
            guard confirmed else { throw CredentialReleaseAuthorizationError.notVerified }
        } catch let error as CredentialReleaseAuthorizationError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let native = error as NSError
            credentialAuthorizationLogger.error("Approval evaluation failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
            throw CredentialReleaseAuthorizationError.classifyNativeFailure(native, authorizationDeadline: deadline)
        }
    }
}
#endif
