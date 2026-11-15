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

    @Test("The native prompt says what each request permits")
    func leaseReasons() {
        func reason(_ purpose: Agentkeyring_V1_Purpose) -> String {
            CredentialReleaseAuthorizationRequest.leaseReason(purpose: purpose, site: "https://example.com/login",
                account: "josh", program: "/usr/local/bin/gh", agent: "Codex")
        }
        #expect(reason(.browserSignIn) == "let Codex sign in to example.com as josh")
        #expect(reason(.program) == "let Codex pass your example.com password for josh to gh")
        #expect(reason(.agentProcess) == "let Codex see your example.com password for josh. It can keep a copy")
    }

    @Test("Only secret-bearing fields need approval")
    func protectedFields() {
        #expect(!AgentCredentialField.username.requiresUserApproval)
        #expect(AgentCredentialField.password.requiresUserApproval)
        #expect(AgentCredentialField.totp.requiresUserApproval)
    }
}
