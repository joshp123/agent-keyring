// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// What the Mac app did, and why, one line each, in the same form as the
// iPhone and Apple Watch: "<UTC time> mac <part> <event> key=value ...". The
// last 500 lines stay in the app's container and go to the unified log too;
// `agent-keyring logs` gathers them with the relay's and the devices'. Lines
// carry IDs, states and reasons: never a password, a key, sealed bytes, or a
// site or account name.

import Foundation
import OSLog
import Synchronization

public enum DiagnosticLog {
    private static let kept = 500
    private static let logger = Logger(subsystem: "com.agentkeyring.app", category: "Diagnostics")
    private static let file = URL.applicationSupportDirectory.appending(path: "AgentKeyring/log.txt")
    private static let lines = Mutex<[String]?>(nil)
    private static let writer = DispatchQueue(label: "com.agentkeyring.app.diagnostics")

    public static func record(_ part: String, _ event: String, _ fields: KeyValuePairs<String, String> = [:]) {
        let time = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        var line = "\(time) mac \(part) \(event)"
        for (key, value) in fields { line += " \(key)=\(quoted(value))" }
        logger.notice("\(line, privacy: .public)")
        let snapshot = lines.withLock { current -> [String] in
            var all = current ?? load()
            all.append(line)
            if all.count > kept { all.removeFirst(all.count - kept) }
            current = all
            return all
        }
        // Only in the app's own container: a test run, which is not sandboxed, would write into his home folder.
        guard file.path.contains("/Library/Containers/") else { return }
        writer.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data((snapshot.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        }
    }

    /// The lines from `since` (Unix seconds, 0 for all) that name `request`, if given.
    public static func recent(since: Int64, request: String) -> [String] {
        let from = since > 0 ? Date(timeIntervalSince1970: TimeInterval(since))
            .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) : ""
        let all = lines.withLock { current -> [String] in
            let all = current ?? load()
            current = all
            return all
        }
        return all.filter { $0 >= from && (request.isEmpty || $0.contains(request)) }
    }

    private static func load() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).suffix(kept).map { $0 }
    }

    private static func quoted(_ value: String) -> String {
        value.isEmpty || value.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\"" : value
    }
}
