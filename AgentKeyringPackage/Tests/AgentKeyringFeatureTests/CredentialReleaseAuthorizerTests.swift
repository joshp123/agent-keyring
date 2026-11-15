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
                == "show the agent the password for user@example.com on accounts.example.com"
        )
    }

    @Test("The native prompt says what each request permits")
    func leaseReasons() {
        func reason(_ purpose: Agentkeyring_V1_Purpose) -> String {
            CredentialReleaseAuthorizationRequest.leaseReason(purpose: purpose, site: "https://example.com/login",
                account: "josh", program: "/usr/local/bin/gh", agent: "Codex")
        }
        #expect(reason(.browserSignIn) == "sign in to example.com as josh")
        #expect(reason(.program) == "give gh the password for josh on example.com")
        #expect(reason(.agentProcess) == "show Codex the password for josh on example.com")
    }

    @Test("Only secret-bearing fields need approval")
    func protectedFields() {
        #expect(!AgentCredentialField.username.requiresUserApproval)
        #expect(AgentCredentialField.password.requiresUserApproval)
        #expect(AgentCredentialField.totp.requiresUserApproval)
    }
}
