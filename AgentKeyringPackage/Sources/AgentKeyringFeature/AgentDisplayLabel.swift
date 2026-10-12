import Darwin
import Foundation

public enum AgentDisplayLabel {
    /// Display only. Process names never establish authority to request a credential.
    public static func parentExecutableName(
        startingPID: pid_t = getppid(),
        processInfo: (pid_t) -> (executablePath: String, parentPID: pid_t)? = { pid in
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
    ) -> String {
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
        let wrapperNames: Set<String> = [
            "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
            "env", "login", "node", "nodejs", "python", "python2", "python3",
            "ruby", "perl", "bun", "deno", "script", "tmux", "screen", "timeout",
            "gtimeout", "nohup", "setsid", "sudo", "su", "terminal", "iterm2",
            "ghostty", "alacritty", "kitty", "wezterm", "wezterm-gui",
        ]
        var ancestorPID = startingPID
        for _ in 0..<16 {
            guard ancestorPID > 1, let ancestor = processInfo(ancestorPID) else { return "an agent" }
            let name = URL(fileURLWithPath: ancestor.executablePath).lastPathComponent
            guard !name.isEmpty else { return "an agent" }
            let normalizedName = name.lowercased()
            if let label = knownAgentNames[normalizedName] { return label }
            let isVersionedPython = normalizedName.hasPrefix("python")
                && normalizedName.dropFirst("python".count).allSatisfy { $0.isNumber || $0 == "." }
            if !wrapperNames.contains(normalizedName) && !isVersionedPython { return name }
            ancestorPID = ancestor.parentPID
        }
        return "an agent"
    }
}
