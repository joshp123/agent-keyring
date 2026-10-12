import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Joined login approvals")
struct CredentialApprovalCoordinatorTests {
    @Test("A decline reaches both waiters, then a retry can ask again")
    func sharedDecline() async throws {
        let approvals = CredentialApprovalCoordinator()
        let authorizer = FakeCredentialAuthorizer()
        let login = UUID()
        let request = CredentialReleaseAuthorizationRequest(destination: "example.com", account: "synthetic", field: .password)
        let first = Task { try await approvals.authorize(credentialID: login) { try await authorizer.authorize(request) } }
        while authorizer.requests.isEmpty { await Task.yield() }
        let second = Task { try await approvals.authorize(credentialID: login) { try await authorizer.authorize(request) } }
        for _ in 0..<20 { await Task.yield() }
        #expect(authorizer.requests.count == 1)
        authorizer.complete(error: .denied)
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await first.value }
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await second.value }
        var retried = false
        try await approvals.authorize(credentialID: login) { retried = true }
        #expect(retried)
    }
}

@MainActor
final class FakeCredentialAuthorizer: CredentialReleaseAuthorizing {
    var requests: [CredentialReleaseAuthorizationRequest] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func authorize(_ request: CredentialReleaseAuthorizationRequest) async throws {
        requests.append(request)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(error: CredentialReleaseAuthorizationError? = nil) {
        let waiting = continuation
        continuation = nil
        if let error { waiting?.resume(throwing: error) }
        else { waiting?.resume() }
    }

    func cancelCurrentAuthorization() {
        complete(error: .expired)
    }
}
