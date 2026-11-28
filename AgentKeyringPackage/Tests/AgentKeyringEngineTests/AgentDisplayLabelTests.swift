import Darwin
import Testing
@testable import AgentKeyringEngine

@Suite("Requesting agent display label")
struct AgentDisplayLabelTests {
    @Test("A shell below Claude Code shows Claude Code")
    func claudeThroughShell() {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/bin/zsh", 101),
            101: ("/nix/store/claude-code/bin/claude", 1),
        ]
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { tree[$0] }) == "Claude Code")
    }

    @Test("Shell and Node wrappers below Codex show Codex")
    func codexThroughShellAndNode() {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/bin/bash", 101),
            101: ("/usr/local/bin/node", 102),
            102: ("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", 1),
        ]
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { tree[$0] }) == "Codex")
    }

    @Test("A known agent above an unknown program takes precedence")
    func unknownAgent() {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/bin/zsh", 101),
            101: ("/usr/bin/python3.14", 102),
            102: ("/opt/bin/MyAgent", 103),
            103: ("/opt/bin/claude", 1),
        ]
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { tree[$0] }) == "Claude Code")
    }

    @Test("An interpreter started by launchd uses the script name")
    func scriptFallback() {
        let result = AgentDisplayLabel.firstAgentAncestor(startingPID: 100, processInfo: { _ in
            ("/bin/bash", 1)
        }, scriptInfo: { _ in "/jobs/daily-bank-download.sh" })
        #expect(result.map { AgentDisplayLabel.executableLabel(path: $0.executablePath) } == "daily-bank-download.sh")
    }

    @Test("A chain containing only wrappers falls back to an agent")
    func wrappersOnly() {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/bin/sh", 101),
            101: ("/usr/bin/env", 102),
            102: ("/usr/bin/tmux", 1),
        ]
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { tree[$0] }) == "an agent")
    }

    @Test("Known desktop and CLI executable names have plain labels", arguments: [
        ("Claude", "Claude Code"),
        ("Claude Helper", "Claude Code"),
        ("Claude Helper (GPU)", "Claude Code"),
        ("Claude Helper (Plugin)", "Claude Code"),
        ("Claude Helper (Renderer)", "Claude Code"),
        ("codex-code-mode-host", "Codex"),
        ("ChatGPT", "Codex"),
        ("agent-browser", "agent-browser"),
        ("pi", "pi"),
    ])
    func knownAgent(executableName: String, expectedLabel: String) {
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { _ in
            ("/Applications/Helpers/\(executableName)", 1)
        }) == expectedLabel)
    }

    @Test("A process cycle or an endless chain of wrappers ends the walk and shows an agent")
    func boundedWalk() {
        let chains: [(pid_t) -> (executablePath: String, parentPID: pid_t)] = [
            { pid in ("/bin/zsh", pid == 100 ? 101 : 100) },
            { pid in (pid == 100_000 ? "/opt/bin/claude" : "/bin/zsh", pid + 1) },
        ]
        for chain in chains {
            var lookups = 0
            let label = AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { pid in
                lookups += 1
                return lookups > 1_000 ? nil : chain(pid)
            })
            #expect(label == "an agent")
            #expect(lookups < 1_000)
        }
    }

    @Test("An unavailable ancestor falls back to an agent")
    func unavailableAncestor() {
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { _ in nil }) == "an agent")
    }
}
