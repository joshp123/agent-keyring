import Testing
import AgentKeyringProtocol
@testable import AgentKeyringFeature

@Suite("Credential release approval")
struct CredentialReleaseAuthorizerTests {
    @Test("The native prompt identifies the field, account and destination")
    func localizedReason() {
        let request = CredentialReleaseAuthorizationRequest(
            destination: "accounts.example.com",
            account: "user@example.com",
            field: .password
        )

        #expect(
            request.localizedReason
                == "let an agent see your password for user@example.com on accounts.example.com"
        )
    }

    @Test("macOS's dialog names the agent, the site and the account, and the machine unless it is this Mac")
    func leaseReasons() {
        #expect(CredentialReleaseAuthorizationRequest.leaseReason(site: "https://example.com/login",
            account: "josh@example.com", agent: "Codex", machine: "Mac mini")
            == "let Codex on Mac mini use your example.com login, josh@example.com")
        #expect(CredentialReleaseAuthorizationRequest.leaseReason(site: "https://example.com/login",
            account: "josh@example.com", agent: "Claude Code")
            == "let Claude Code use your example.com login, josh@example.com")
    }

    @Test("Only secret-bearing fields need approval")
    func protectedFields() {
        #expect(!AgentCredentialField.username.requiresUserApproval)
        #expect(AgentCredentialField.password.requiresUserApproval)
        #expect(AgentCredentialField.totp.requiresUserApproval)
    }
}
