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
        grants.approve(login, action: .acquire)
        #expect(grants.contains(login, action: .acquire))
        #expect(!grants.contains(UUID(), action: .acquire))
        #expect(!CredentialApprovalGrants().contains(login, action: .acquire))
        now = now.addingTimeInterval(1_799)
        #expect(grants.contains(login, action: .acquire))
        now = now.addingTimeInterval(1)
        #expect(!grants.contains(login, action: .acquire))
    }

    @Test("Ending all grants revokes every login")
    func endAll() {
        let grants = CredentialApprovalGrants()
        let first = UUID()
        let second = UUID()
        grants.approve(first, action: .acquire)
        grants.approve(second, action: .acquire)
        grants.endAll()
        #expect(!grants.contains(first, action: .acquire))
        #expect(!grants.contains(second, action: .acquire))
    }
}
