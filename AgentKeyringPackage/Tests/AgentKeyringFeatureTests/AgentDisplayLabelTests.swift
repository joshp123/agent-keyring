import Darwin
import Testing
@testable import AgentKeyringFeature

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

    @Test("An unknown agent uses the first non-wrapper executable")
    func unknownAgent() {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/bin/zsh", 101),
            101: ("/usr/bin/python3.14", 102),
            102: ("/opt/bin/MyAgent", 103),
            103: ("/opt/bin/claude", 1),
        ]
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { tree[$0] }) == "MyAgent")
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

    @Test("The sixteenth ancestor is checked, but the seventeenth is not")
    func hopLimit() {
        for agentPID: pid_t in [115, 116] {
            var visitedPIDs: [pid_t] = []
            let label = AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { pid in
                visitedPIDs.append(pid)
                return (pid == agentPID ? "/opt/bin/claude" : "/bin/zsh", pid + 1)
            })
            #expect(label == (agentPID == 115 ? "Claude Code" : "an agent"))
            #expect(visitedPIDs == Array(100...115))
        }
    }

    @Test("An unavailable ancestor falls back to an agent")
    func unavailableAncestor() {
        #expect(AgentDisplayLabel.parentExecutableName(startingPID: 100, processInfo: { _ in nil }) == "an agent")
    }
}
