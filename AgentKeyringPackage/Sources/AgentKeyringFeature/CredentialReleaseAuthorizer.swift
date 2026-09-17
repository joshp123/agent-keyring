import AppKit
import Foundation
import LocalAuthentication

public struct CredentialReleaseAuthorizationRequest: Equatable, Sendable {
    public let destination: String
    public let account: String
    public let field: AgentCredentialField
    public let credentialTitle: String
    public let expirationSeconds: Int?
    public let authorizationDeadline: Date

    public init(
        destination: String,
        account: String,
        field: AgentCredentialField,
        credentialTitle: String? = nil,
        expirationSeconds: Int? = 30,
        authorizationDeadline: Date = Date().addingTimeInterval(120)
    ) {
        self.destination = destination
        self.account = account
        self.field = field
        self.credentialTitle = credentialTitle ?? account
        self.expirationSeconds = expirationSeconds
        self.authorizationDeadline = authorizationDeadline
    }

    public var localizedReason: String {
        let value =
            switch field {
            case .username: "username"
            case .password: "password"
            case .totp: "verification code"
            }
        return "release the \(value) for \(account) to a local agent for \(destination)"
    }
}

public enum CredentialReleaseAuthorizationError: Error, LocalizedError, Sendable {
    case unavailable
    case busy
    case denied
    case expired

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Touch ID or Apple Watch approval is not available."
        case .busy:
            "Another credential request is already awaiting approval."
        case .denied:
            "Credential access was not approved."
        case .expired:
            "The credential request expired before it was approved."
        }
    }
}

@MainActor
public protocol CredentialReleaseAuthorizing {
    func authorize(_ request: CredentialReleaseAuthorizationRequest) async throws
    func cancelCurrentAuthorization()
}

public extension CredentialReleaseAuthorizing {
    func cancelCurrentAuthorization() {}
}

@MainActor
public final class LocalCredentialReleaseAuthorizer: CredentialReleaseAuthorizing {
    private var activeContext: LAContext?

    public init() {}

    public func authorize(_ request: CredentialReleaseAuthorizationRequest) async throws {
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
            guard
                try await context.evaluatePolicy(
                    policy,
                    localizedReason: request.localizedReason
                )
            else {
                throw CredentialReleaseAuthorizationError.denied
            }
        } catch let error as CredentialReleaseAuthorizationError {
            throw error
        } catch {
            if request.authorizationDeadline <= Date() {
                throw CredentialReleaseAuthorizationError.expired
            }
            let nsError = error as NSError
            if nsError.domain == LAError.errorDomain,
                let code = LAError.Code(rawValue: nsError.code),
                [.biometryNotAvailable, .companionNotAvailable, .notInteractive].contains(code)
            {
                throw CredentialReleaseAuthorizationError.unavailable
            }
            throw CredentialReleaseAuthorizationError.denied
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
