import AgentKeyringTestSupport
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Per-login approval grants")
struct CredentialApprovalGrantsTests {
    @Test("Grants last thirty minutes, cover one login, and stay in memory")
    func lifetimeAndScope() {
        var now = Date(timeIntervalSince1970: 1_000)
        let grants = CredentialApprovalGrants(now: { now })
        let login = UUID()
        grants.approve(login, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "example.com", account: "synthetic@example.com")
        #expect(grants.contains(login, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        #expect(!grants.contains(UUID(), action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        #expect(!CredentialApprovalGrants().contains(login, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        now = now.addingTimeInterval(1_799)
        #expect(grants.contains(login, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        now = now.addingTimeInterval(1)
        #expect(!grants.contains(login, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
    }

    @Test("Ending all grants revokes every login")
    func endAll() {
        let grants = CredentialApprovalGrants()
        let first = UUID()
        let second = UUID()
        grants.approve(first, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "example.com", account: "synthetic@example.com")
        grants.approve(second, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "example.com", account: "synthetic@example.com")
        grants.endAll()
        #expect(!grants.contains(first, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        #expect(!grants.contains(second, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
    }

    @Test("The menu lists live grants and ending one preserves other logins and actions")
    func activeGrantsAndIndividualRevocation() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let grants = CredentialApprovalGrants(now: { now })
        let login = UUID()
        let otherLogin = UUID()
        grants.approve(login, action: .fill, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "example.com", account: "first@example.com")
        grants.approve(login, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "example.com", account: "first@example.com")
        grants.approve(otherLogin, action: .fill, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "other.example", account: "second@example.com")
        let listed = grants.active
        #expect(listed.count == 3)
        let fillGrant = try #require(listed.first { $0.id.credentialID == login && $0.id.action == .fill })
        #expect(fillGrant.site == "example.com")
        #expect(fillGrant.account == "first@example.com")
        #expect(fillGrant.expiresAt == now.addingTimeInterval(1_800))
        grants.end(fillGrant.id)
        #expect(!grants.contains(login, action: .fill, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        #expect(grants.contains(login, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        #expect(grants.contains(otherLogin, action: .fill, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!))
        #expect(grants.active.count == 2)
        now = now.addingTimeInterval(1_800)
        #expect(grants.active.isEmpty)
    }

}
