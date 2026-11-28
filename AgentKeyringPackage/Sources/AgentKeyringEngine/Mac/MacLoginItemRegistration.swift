// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// "Open Agent Keyring at login": macOS does not open a quit app for a push, so
// a Mac that should answer other computers' requests keeps the app running.
// Beside it in Settings, whether the daily version check may count this Mac.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringSealing
import Foundation
import ServiceManagement

@available(macOS 26.0, *)
extension MacKeyringEngine {
    /// Nil when macOS cannot say (the app is not in Applications, or not signed).
    public var opensAtLogin: Bool? {
        _ = loginItemRevision
        switch SMAppService.mainApp.status {
        case .enabled: return true
        case .notRegistered, .requiresApproval: return false
        default: return nil
        }
    }

    public func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            KeyringDiagnosticLog.mac.noteDeviceEvent("login-item", on ? "on" : "off", [:])
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("login-item", "not-changed", ["reason": "\(error)"])
            if on, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        loginItemRevision &+= 1
    }

    /// The daily anonymous version check (VersionCheck) may count this Mac.
    public var anonymousTelemetry: Bool {
        _ = telemetryRevision
        return !VersionCheck.isDisabled
    }

    public func setAnonymousTelemetry(_ on: Bool) {
        VersionCheck.setNoTelemetry(!on)
        telemetryRevision &+= 1
    }
}
#endif
