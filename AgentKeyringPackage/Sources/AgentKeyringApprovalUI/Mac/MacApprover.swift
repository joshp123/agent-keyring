// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// What this Mac can approve with right now: a closed lid turns Touch ID off,
// and a Mac with Touch ID but no fingerprint cannot approve until one is added.

#if os(macOS)
import Foundation
import IOKit
import LocalAuthentication

public enum MacApprover {
    /// The built-in display's lid is shut. Always false on a Mac without a lid.
    public static var lidIsClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    /// Touch ID is there but has no fingerprint, and no Apple Watch can approve instead.
    public static var needsFingerprint: Bool {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return false }
        guard error?.code == LAError.Code.biometryNotEnrolled.rawValue else { return false }
        return !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithCompanion, error: nil)
    }

    /// System Settings at Touch ID & Password.
    public static let touchIDSettings = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension")!
}
#endif
