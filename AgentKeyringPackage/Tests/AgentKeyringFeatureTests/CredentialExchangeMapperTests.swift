import AuthenticationServices
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Apple credential exchange mapping")
struct CredentialExchangeMapperTests {
    @Test("Passwords and TOTP map while passkeys remain parked")
    func mapsSupportedCredentials() {
        let editableUser = ASImportableEditableField(
            id: nil,
            fieldType: .string,
            value: "agent@example.com"
        )
        let editablePassword = ASImportableEditableField(
            id: nil,
            fieldType: .concealedString,
            value: "password-canary"
        )
        let item = ASImportableItem(
            id: Data("item".utf8),
            created: Date(timeIntervalSince1970: 100),
            lastModified: Date(timeIntervalSince1970: 200),
            title: "Example",
            scope: ASImportableCredentialScope(
                urls: [URL(string: "https://example.com")!]
            ),
            credentials: [
                .basicAuthentication(
                    ASImportableCredential.BasicAuthentication(
                        userName: editableUser,
                        password: editablePassword
                    )
                ),
                .totp(
                    ASImportableCredential.TOTP(
                        secret: Data([1, 2, 3]),
                        period: 30,
                        digits: 6,
                        userName: "agent@example.com",
                        algorithm: .sha1,
                        issuer: "Example"
                    )
                ),
                .generatedPassword(
                    ASImportableCredential.GeneratedPassword(password: "parked")
                ),
                .passkey(
                    ASImportableCredential.Passkey(
                        credentialID: Data("credential".utf8),
                        relyingPartyIdentifier: "example.com",
                        userName: "agent@example.com",
                        userDisplayName: "Agent",
                        userHandle: Data("user".utf8),
                        key: Data("private-key-canary".utf8)
                    )
                ),
            ]
        )
        let account = ASImportableAccount(
            id: Data("account".utf8),
            userName: "",
            email: "",
            collections: [],
            items: [item]
        )
        let exportedData = ASExportedCredentialData(
            accounts: [account],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            timestamp: Date(timeIntervalSince1970: 300)
        )

        let batch = CredentialExchangeMapper().map(exportedData)

        #expect(batch.items.count == 1)
        #expect(batch.items.first?.credentials.count == 2)
        #expect(batch.skippedCredentialCount == 2)
        #expect(batch.skippedCredentialSummary?.passkeyCount == 1)
        #expect(batch.skippedCredentialSummary?.missingPasswordCount == 0)
        #expect(batch.skippedCredentialSummary?.otherCount == 1)
        #expect(batch.items.first?.origins == ["https://example.com"])
    }
}
