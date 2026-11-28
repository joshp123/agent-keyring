#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import Testing

@MainActor
struct OwnerApprovalLifetimeTests {
    @Test func closingAQuestionCannotAnswerItLater() {
        var completed: [Bool] = []
        var performed = false
        let world = SandboxWorld()
        let approval = OwnerApproval(action: "allow", reason: "test", authenticate: { SandboxOwnerAuthentication(world) { performed = true } },
            finish: { completed.append($0) })
        approval.cancel()
        approval.cancel()
        approval.retry()
        approval.begin()
        #expect(completed == [false])
        #expect(!performed)
        #expect(!approval.canBegin)
    }

    @Test func withdrawingAQuestionDoesNotSubmitADecision() {
        var completed = false
        let world = SandboxWorld()
        let approval = OwnerApproval(action: "allow", reason: "test", authenticate: { SandboxOwnerAuthentication(world) },
            finish: { _ in completed = true })
        approval.invalidate()
        approval.cancel()
        approval.begin()
        #expect(!completed)
        #expect(!approval.canBegin)
    }

    /// An approved question runs its work once and finishes; the sandbox's Touch ID is its `ownerApproval` effect.
    @Test func approvingRunsTheWorkOnce() async {
        var completed: [Bool] = []
        var performed = 0
        let world = SandboxWorld()
        let approval = OwnerApproval(action: "allow", reason: "test", authenticate: { SandboxOwnerAuthentication(world) { performed += 1 } },
            finish: { completed.append($0) })
        approval.begin()
        while approval.isWaiting { await Task.yield() }
        approval.begin()
        #expect(completed == [true])
        #expect(performed == 1)
        #expect(world.effects.ran == [.ownerApproval])
    }
}
#endif
