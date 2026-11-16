import Darwin
import Foundation

public enum AgentDisplayLabel {
    /// Display only. Process names never establish authority to request a credential.
    public static func parentExecutableName(
        startingPID: pid_t = getppid(),
        processInfo: (pid_t) -> (executablePath: String, parentPID: pid_t)? = processInformation
    ) -> String {
        guard let ancestor = firstAgentAncestor(startingPID: startingPID, processInfo: processInfo) else { return "an agent" }
        return executableLabel(path: ancestor.executablePath)
    }

    public static func processInformation(_ pid: pid_t) -> (executablePath: String, parentPID: pid_t)? {
        var process = kinfo_proc()
        var processSize = MemoryLayout<kinfo_proc>.size
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, UInt32(query.count), &process, &processSize, nil, 0) == 0,
              processSize > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executablePath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (executablePath, process.kp_eproc.e_ppid)
    }

    static func executableLabel(path: String) -> String {
        let knownAgentNames = [
            "claude": "Claude Code",
            "claude helper": "Claude Code",
            "claude helper (gpu)": "Claude Code",
            "claude helper (plugin)": "Claude Code",
            "claude helper (renderer)": "Claude Code",
            "codex": "Codex",
            "codex-code-mode-host": "Codex",
            "chatgpt": "Codex",
            "agent-browser": "agent-browser",
            "pi": "pi",
        ]
        let name = URL(fileURLWithPath: path).lastPathComponent
        return knownAgentNames[name.lowercased()] ?? (name.isEmpty ? "an agent" : name)
    }

    static func firstAgentAncestor(startingPID: pid_t,
        processInfo: (pid_t) -> (executablePath: String, parentPID: pid_t)? = processInformation,
        scriptInfo: (pid_t) -> String? = scriptName
    ) -> (processIdentifier: pid_t, executablePath: String)? {
        let wrapperNames: Set<String> = [
            "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
            "env", "login", "node", "nodejs", "python", "python2", "python3",
            "ruby", "perl", "bun", "deno", "script", "tmux", "screen", "timeout",
            "gtimeout", "nohup", "setsid", "sudo", "su", "terminal", "iterm2",
            "ghostty", "alacritty", "kitty", "wezterm", "wezterm-gui",
        ]
        let interpreters: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "node", "nodejs", "ruby", "perl", "bun", "deno"]
        var ancestorPID = startingPID
        var fallback: (processIdentifier: pid_t, executablePath: String)?
        for _ in 0..<16 {
            guard ancestorPID > 1, let ancestor = processInfo(ancestorPID) else { break }
            let name = URL(fileURLWithPath: ancestor.executablePath).lastPathComponent
            guard !name.isEmpty else { break }
            let normalizedName = name.lowercased()
            let isVersionedPython = normalizedName.hasPrefix("python")
                && normalizedName.dropFirst("python".count).allSatisfy { $0.isNumber || $0 == "." }
            if !wrapperNames.contains(normalizedName) && !isVersionedPython {
                if ["claude", "claude helper", "claude helper (gpu)", "claude helper (plugin)",
                    "claude helper (renderer)", "codex", "codex-code-mode-host", "chatgpt"].contains(normalizedName) {
                    return (ancestorPID, ancestor.executablePath)
                }
                if fallback == nil { fallback = (ancestorPID, ancestor.executablePath) }
            } else if fallback == nil, (interpreters.contains(normalizedName) || isVersionedPython), let script = scriptInfo(ancestorPID) {
                fallback = (ancestorPID, script)
            }
            ancestorPID = ancestor.parentPID
        }
        return fallback
    }

    /// Read argv from the kernel; use only a script path, never its arguments.
    static func scriptName(_ pid: pid_t) -> String? {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&query, UInt32(query.count), nil, &length, nil, 0) == 0,
              length > MemoryLayout<Int32>.size else { return nil }
        var data = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &data, &length, nil, 0) == 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < length && data[index] != 0 { index += 1 }
        while index < length && data[index] == 0 { index += 1 }
        var args: [String] = []
        while index < length && args.count < 2 {
            let start = index
            while index < length && data[index] != 0 { index += 1 }
            guard index > start else { break }
            args.append(String(decoding: data[start..<index], as: UTF8.self))
            index += 1
        }
        guard args.count == 2, !args[1].hasPrefix("-"), !args[1].contains("="),
              args[1].contains("/") || args[1].contains(".") else { return nil }
        return args[1]
    }
}
