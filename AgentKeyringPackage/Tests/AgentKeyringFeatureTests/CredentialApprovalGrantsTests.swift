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
        grants.approve(login)
        #expect(grants.contains(login))
        #expect(!grants.contains(UUID()))
        #expect(!CredentialApprovalGrants().contains(login))
        now = now.addingTimeInterval(1_799)
        #expect(grants.contains(login))
        now = now.addingTimeInterval(1)
        #expect(!grants.contains(login))
    }

    @Test("Ending all grants revokes every login")
    func endAll() {
        let grants = CredentialApprovalGrants()
        let first = UUID()
        let second = UUID()
        grants.approve(first)
        grants.approve(second)
        grants.endAll()
        #expect(!grants.contains(first))
        #expect(!grants.contains(second))
    }
}
