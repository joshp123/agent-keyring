import Darwin
import Foundation

public enum AgentDisplayLabel {
    /// Display only. Process names never establish authority to request a credential.
    public static func parentExecutableName() -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getppid(), &path, UInt32(path.count)) > 0 else { return "an agent" }
        let executablePath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        return name.isEmpty ? "an agent" : name
    }
}
