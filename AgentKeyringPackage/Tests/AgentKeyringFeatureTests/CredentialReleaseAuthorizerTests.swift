import Testing
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
                == "release the password for user@example.com to a local agent for accounts.example.com"
        )
    }

    @Test("Only secret-bearing fields need approval")
    func protectedFields() {
        #expect(!AgentCredentialField.username.requiresUserApproval)
        #expect(AgentCredentialField.password.requiresUserApproval)
        #expect(AgentCredentialField.totp.requiresUserApproval)
    }
}
