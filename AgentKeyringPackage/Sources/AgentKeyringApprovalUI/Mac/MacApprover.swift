// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// What this Mac can approve with right now: a closed lid turns Touch ID off,
// and a Mac with Touch ID but no fingerprint cannot approve until one is added.
// One value, read again when the screens change (the lid), the Mac wakes, or
// the app becomes active (a fingerprint added); the first-run window, the
// request panel and the presenter all read it.

#if os(macOS)
import AppKit
import Foundation
import IOKit
import LocalAuthentication
import Observation

@MainActor
@Observable
public final class MacApprover {
    public enum State: Equatable, Sendable {
        case ready
        case lidClosed
        case needsFingerprint
    }

    public static let shared = MacApprover()
    public internal(set) var state: State = MacApprover.read()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Follows the lid, waking and fingerprints for as long as the app runs.
    public func follow() {
        guard observers.isEmpty else { return }
        let refresh: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { MacApprover.shared.state = MacApprover.read() } }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: refresh))
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
            queue: .main, using: refresh))
    }

    nonisolated static func read() -> State {
        lidIsClosed ? .lidClosed : needsFingerprint ? .needsFingerprint : .ready
    }

    /// The built-in display's lid is shut. Always false on a Mac without a lid.
    nonisolated static var lidIsClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    /// Touch ID is there but has no fingerprint, and no Apple Watch can approve instead.
    nonisolated static var needsFingerprint: Bool {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return false }
        guard error?.code == LAError.Code.biometryNotEnrolled.rawValue else { return false }
        return !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithCompanion, error: nil)
    }

    /// System Settings at Touch ID & Password.
    public nonisolated static let touchIDSettings = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension")!
}
#endif
