// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// What happened, in plain lines, in the app's own container
// (Library/Caches/diagnostics.log), so a test sitting can read it with
// `devicectl device copy from` without anyone opening Console. Never a secret.

import Foundation
import OSLog

public enum PhoneDiagnostics {
    private static let logger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Diagnostics")

    public static func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        let url = URL.cachesDirectory.appending(path: "diagnostics.log")
        let stamped = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: stamped)
        } else {
            try? stamped.write(to: url)
        }
    }
}
