import AgentKeyringTestSupport
import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Harness attribution")
struct AgentRequesterAttributionTests {
    @Test("The socket peer's ancestry supplies the harness, session and folder", arguments: ["claude", "codex"])
    func harnessAncestor(executable: String) throws {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/opt/bin/agent-keyring", 101), 101: ("/bin/zsh", 102),
            102: ("/usr/bin/python3", 103), 103: ("/opt/bin/\(executable)", 1),
        ]
        let start = HarnessProcessStartTime(seconds: 1_000, microseconds: 123)
        let requester = AgentRequester.attribution(peerProcessIdentifier: 100, processInfo: { tree[$0] },
            startTime: { pid in #expect(pid == 103); return start },
            folder: { pid in #expect(pid == 103); return "/fixture/project" })
        #expect(requester.name == (executable == "claude" ? "Claude Code" : "Codex"))
        #expect(requester.displayLabel == requester.name)
        #expect(requester.session == HarnessSession(processIdentifier: 103, processStartTime: start))
        #expect(requester.workingDirectory == "/fixture/project")
    }

    @Test("A process that changes during attribution cannot receive a reusable session grant")
    func unstableProcess() {
        var reads = 0
        let requester = AgentRequester.attribution(peerProcessIdentifier: 100,
            processInfo: { _ in ("/opt/bin/claude", 1) }, startTime: { _ in
                reads += 1
                return HarnessProcessStartTime(seconds: UInt64(reads), microseconds: 0)
            }, folder: { _ in "/fixture" })
        #expect(requester.session == nil)
    }

}
