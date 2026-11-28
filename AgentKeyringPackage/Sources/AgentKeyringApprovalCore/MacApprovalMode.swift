// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// How Josh approves on this Mac, and what the Mac has to approve with. The
// mode is chosen once, when the Mac's keys are made, and saved with them: an
// existing vault never changes mode. A Mac with Touch ID uses Touch ID or the
// Watch. A Mac without Touch ID (a Mac mini or Mac Studio) can opt in to its
// login password; its keys are still Secure Enclave keys.

import Foundation
#if os(macOS)
import CryptoKit
import IOKit
import LocalAuthentication
#endif

public enum MacApprovalMode: String, Sendable {
    /// Touch ID or a paired Apple Watch.
    case biometricOrCompanion
    /// The Mac's login password, chosen on a Mac without Touch ID. macOS also
    /// accepts Touch ID or a Watch here if one is added later.
    case devicePassword

    /// This Mac's mode, set when its keys are loaded or made. Before then, and
    /// on iPhone, Touch ID or the Watch. Written only on the main thread; each
    /// change is posted as `changed`, so what is on screen follows it.
    nonisolated(unsafe) public static var current: MacApprovalMode = .biometricOrCompanion {
        didSet { if current != oldValue { NotificationCenter.default.post(name: changed, object: nil) } }
    }
    public static let changed = Notification.Name("com.agentkeyring.approvalModeChanged")
}

#if os(macOS)
extension MacApprovalMode {
    /// The policy macOS's dialog asks for. "TouchIDOnly" (a launch argument,
    /// -TouchIDOnly YES) leaves the Watch out, so a rehearsal never asks his wrist.
    public var policy: LAPolicy {
        switch self {
        case .biometricOrCompanion:
            UserDefaults.standard.bool(forKey: "TouchIDOnly") ? .deviceOwnerAuthenticationWithBiometrics
                : .deviceOwnerAuthenticationWithBiometricsOrCompanion
        case .devicePassword:
            .deviceOwnerAuthentication
        }
    }

    /// The access control of the keys that open and sign only after Josh approves.
    public var keyFlags: SecAccessControlCreateFlags {
        switch self {
        case .biometricOrCompanion: [.privateKeyUsage, .biometryCurrentSet, .or, .companion]
        case .devicePassword: [.privateKeyUsage, .userPresence]
        }
    }

    /// Prepares macOS's dialog. With Touch ID or the Watch the dialog offers
    /// no password; with the Mac password it must.
    public func prepareAuthenticationContext(_ context: LAContext) {
        context.touchIDAuthenticationAllowableReuseDuration = 0
        if self == .biometricOrCompanion { context.localizedFallbackTitle = "" }
    }
}

/// What this Mac has, read from macOS. One reading serves both the setup
/// window (`hardware`) and whether Josh can approve now (`MacApprover`).
public struct MacProbe: Equatable, Sendable {
    /// The Mac has a Secure Enclave to keep keys in.
    public var secureEnclave: Bool
    /// The built-in display's lid is shut. Always false on a Mac without a lid.
    public var lidClosed: Bool
    /// Why Touch ID can't be used now; nil when it can.
    public var biometry: LAError.Code?
    /// An Apple Watch can approve.
    public var companion: Bool

    public init(secureEnclave: Bool = true, lidClosed: Bool = false, biometry: LAError.Code? = nil, companion: Bool = false) {
        self.secureEnclave = secureEnclave
        self.lidClosed = lidClosed
        self.biometry = biometry
        self.companion = companion
    }

    public static func readMacProbe() -> MacProbe {
        let context = LAContext()
        var error: NSError?
        let biometry = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? nil : LAError.Code(rawValue: error?.code ?? LAError.Code.biometryNotAvailable.rawValue)
        // "TouchIDOnly" leaves the Watch out of approvals, so it is not counted as one here either.
        let companion = !UserDefaults.standard.bool(forKey: "TouchIDOnly")
            && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithCompanion, error: nil)
        return MacProbe(secureEnclave: SecureEnclave.isAvailable, lidClosed: lidIsClosed, biometry: biometry, companion: companion)
    }

    /// What kind of Mac this is, for a Mac with no keys yet.
    public var hardware: MacHardware {
        guard secureEnclave else { return .noSecureEnclave }
        // A MacBook with its lid shut reports no Touch ID, but it has one.
        if lidClosed { return .touchID }
        switch biometry {
        case .biometryNotPaired?, .biometryNotAvailable?: return .noTouchID
        default: return .touchID
        }
    }

    static var lidIsClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }
}

public enum MacHardware: Equatable, Sendable {
    /// No Secure Enclave (an Intel Mac without a T2 chip, or a virtual
    /// machine): nothing can lock passwords to this Mac.
    case noSecureEnclave
    /// Touch ID is built in or paired, even if it is off now (lid shut,
    /// keyboard disconnected, no fingerprint yet).
    case touchID
    /// A Secure Enclave but no Touch ID: a Mac mini or Mac Studio without a
    /// Touch ID keyboard. An Apple Watch alone doesn't count: keys that need
    /// Touch ID can't be made here.
    case noTouchID
}

/// What this Mac can approve with right now (`MacApprover` in the screens follows it).
public enum MacApproverState: Equatable, Sendable {
    case ready
    case lidClosed
    case needsFingerprint
    /// Touch ID keys, but no Touch ID keyboard connected and no Watch: approve on the iPhone or Apple Watch, or reconnect it.
    case touchIDMissing

    public init(mode: MacApprovalMode, _ probe: MacProbe) {
        // macOS's password dialog needs no lid, fingerprint or keyboard.
        guard mode == .biometricOrCompanion else { self = .ready; return }
        // Touch ID works (a Touch ID keyboard with the lid shut too), or is locked out and macOS's dialog unlocks it.
        guard let biometry = probe.biometry, biometry != .biometryLockout else { self = .ready; return }
        // A paired Apple Watch still approves in closed-clamshell mode or without a Touch ID keyboard.
        if probe.companion { self = .ready; return }
        if probe.lidClosed { self = .lidClosed; return }
        switch biometry {
        case .biometryNotEnrolled: self = .needsFingerprint
        case .biometryNotPaired, .biometryNotAvailable, .biometryDisconnected: self = .touchIDMissing
        default: self = .ready
        }
    }
}

/// What approves on this Mac now, for the green button's words.
public enum MacApproverKind: Equatable, Sendable {
    case touchID
    case watch
    case password
    case none

    public init(mode: MacApprovalMode, _ probe: MacProbe) {
        if mode == .devicePassword { self = .password; return }
        if probe.biometry == nil || probe.biometry == .biometryLockout { self = .touchID; return }
        self = probe.companion ? .watch : .none
    }
}

/// Why Josh's approval in macOS's dialog did not go through.
public enum OwnerAuthenticationFailure: Equatable, Sendable {
    /// He cancelled, or macOS or the app closed the dialog.
    case interrupted
    /// Nothing on this Mac can approve now: no Touch ID, Watch or passcode.
    case approverUnavailable
    /// Anything else: the error says what.
    case other

    public init(_ error: Error) {
        let native = error as NSError
        guard native.domain == LAError.errorDomain, let code = LAError.Code(rawValue: native.code) else { self = .other; return }
        switch code {
        case .systemCancel, .appCancel, .userCancel: self = .interrupted
        case .companionNotAvailable, .biometryNotAvailable, .biometryNotEnrolled, .biometryNotPaired, .biometryDisconnected, .passcodeNotSet:
            self = .approverUnavailable
        default: self = .other
        }
    }

    /// Cancel, Escape, clicking away or closing a panel: not an answer. Backends report those as
    /// `CancellationError` or as LocalAuthentication's own cancels.
    public static func isCancel(_ error: Error) -> Bool {
        error is CancellationError || Self(error) == .interrupted
    }
}

/// Whether macOS can ask for this policy now.
public func canAsk(_ context: LAContext, _ policy: LAPolicy) -> Bool {
    context.canEvaluatePolicy(policy, error: nil)
}
#endif
