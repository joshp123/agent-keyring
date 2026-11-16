#if os(macOS)
import AgentKeyringApprovalUI
import Testing

@MainActor
struct OwnerApprovalLifetimeTests {
    @Test func closingAQuestionCannotAnswerItLater() {
        var completed: [Bool] = []
        var performed = false
        let approval = OwnerApproval(action: "allow", reason: "test", perform: { _ in performed = true },
            finish: { completed.append($0) })
        approval.cancel()
        approval.cancel()
        approval.retry()
        approval.begin()
        #expect(completed == [false])
        #expect(!performed)
        #expect(approval.context == nil)
    }

    @Test func withdrawingAQuestionDoesNotSubmitADecision() {
        var completed = false
        let approval = OwnerApproval(action: "allow", reason: "test", perform: { _ in },
            finish: { _ in completed = true })
        approval.invalidate()
        approval.cancel()
        approval.begin()
        #expect(!completed)
        #expect(approval.context == nil)
    }
}
#endif
