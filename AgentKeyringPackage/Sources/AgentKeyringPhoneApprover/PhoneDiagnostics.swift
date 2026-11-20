// Written by AI on 2026.11.18 by model Claude Opus 5.5; the shared ring on 2026.11.20.
//
// What happened, in plain lines, in the ring the iPhone app and its
// notification extension share (DeviceLog). Never a secret.

import AgentKeyringSealing
import Foundation

public enum PhoneDiagnostics {
    /// The app, or its notification extension.
    public static let log = DeviceLog(device: Bundle.main.bundleURL.pathExtension == "appex" ? "iphone-notice" : "iphone")

    public static func note(_ line: String) { log.note("app", "note", ["msg": line]) }
}
