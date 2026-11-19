import Testing
import AgentKeyringProtocol
@testable import AgentKeyringFeature

@Suite("Credential release approval")
struct CredentialReleaseAuthorizerTests {
    @Test("macOS's dialog names the agent, the site and the account, and the machine unless it is this Mac")
    func leaseReasons() {
        #expect(ApprovalSentence.lease(site: "https://example.com/login",
            account: "josh@example.com", agent: "Codex", machine: "Mac mini")
            == "let Codex on Mac mini use your example.com password, josh@example.com")
        #expect(ApprovalSentence.lease(site: "https://example.com/login",
            account: "josh@example.com", agent: "Claude Code")
            == "let Claude Code use your example.com password, josh@example.com")
    }
}
