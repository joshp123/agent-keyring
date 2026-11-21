// Written by AI on 2026.11.21 by model claude opus 5.5.
// Sort with AI: Josh copies the prompt to an agent, copies its reply back and
// clicks Apply Suggestions. Each suggestion becomes a pending change he
// reviews in the table and saves with Touch ID; nothing is saved here.
#if os(macOS)
import Foundation
import LocalAuthentication
import Testing
@testable import AgentKeyringApprovalUI

@MainActor
@Suite struct SortWithAI {
    final class Backend: MainWindowBackend {
        func updates() -> AsyncStream<MainSnapshot> { AsyncStream { $0.finish() } }
        func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws {}
        func remove(id: String, context: LAContext) async throws {}
        func importAgain() {}
        func sendPractice(deviceID: String) {}
    }

    let news = LoginRow(id: UUID(), site: "news.example", account: "you@example.com", rule: .ask)
    let bank = LoginRow(id: UUID(), site: "bank.example", account: "you@example.com", rule: .ask)
    let shop = LoginRow(id: UUID(), site: "shop.example", account: "orders@example.com", rule: .automatic)

    func model() -> MacMainModel {
        MacMainModel(backend: Backend(), initial: MainSnapshot(logins: [news, bank, shop], importedAt: nil))
    }

    @Test func theAgentsReplyInThePromptsOwnFormatBecomesPendingChanges() {
        let model = model()
        let reply = "Here are my suggestions:\nnews.example\tyou@example.com\tAutomatic\nbank.example\tyou@example.com\tBlocked\n"
        #expect(model.applySuggestions(reply) == 2)
        #expect(model.pending == [news.id: .automatic, bank.id: .blocked])
    }

    @Test func aMarkdownTableWithTheCurrentRuleAlsoWorks() {
        let model = model()
        let reply = """
        | Website | Account | Current | Suggested |
        |---|---|---|---|
        | bank.example | you@example.com | Ask | **Blocked** |
        | shop.example | orders@example.com | Automatic | Automatic |
        """
        #expect(model.applySuggestions(reply) == 1)
        #expect(model.pending == [bank.id: .blocked])
    }

    @Test func thePromptItselfOrAnythingElseChangesNothing() {
        let model = model()
        #expect(model.applySuggestions("Sure, I can help with that.") == 0)
        #expect(model.applySuggestions(model.sortPrompt) == 0)
        #expect(model.pending.isEmpty)
    }
}
#endif
