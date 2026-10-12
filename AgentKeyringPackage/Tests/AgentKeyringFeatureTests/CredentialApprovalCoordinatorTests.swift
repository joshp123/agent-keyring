import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Joined login approvals")
struct CredentialApprovalCoordinatorTests {
    @Test("A decline reaches both waiters, then a retry can ask again")
    func sharedDecline() async throws {
        let approvals = CredentialApprovalCoordinator(lockState: FakeCredentialSessionLockState())
        let authorizer = FakeCredentialAuthorizer()
        let login = UUID()
        let request = CredentialReleaseAuthorizationRequest(destination: "example.com", account: "synthetic", field: .password)
        let first = Task { try await approvals.authorize(credentialID: login, authorizationDeadline: request.authorizationDeadline) { try await authorizer.authorize(request) } }
        while authorizer.requests.isEmpty { await Task.yield() }
        let second = Task { try await approvals.authorize(credentialID: login, authorizationDeadline: request.authorizationDeadline) { try await authorizer.authorize(request) } }
        for _ in 0..<20 { await Task.yield() }
        #expect(authorizer.requests.count == 1)
        authorizer.complete(error: .denied)
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await first.value }
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await second.value }
        var retried = false
        try await approvals.authorize(credentialID: login, authorizationDeadline: request.authorizationDeadline) { retried = true }
        #expect(retried)
    }
    @Test("Joined requests receive the original asked time")
    func joinedStatus() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let approvals = CredentialApprovalCoordinator(lockState: FakeCredentialSessionLockState(), now: { now })
        let authorizer = FakeCredentialAuthorizer()
        let login = UUID()
        var firstStatus: [AgentApprovalProgress] = []
        var secondStatus: [AgentApprovalProgress] = []
        let request = CredentialReleaseAuthorizationRequest(destination: "example.com", account: "synthetic", field: .password)
        let first = Task { try await approvals.authorize(credentialID: login, authorizationDeadline: now.addingTimeInterval(600),
            onProgress: { firstStatus.append($0) }) { try await authorizer.authorize(request) } }
        while authorizer.requests.isEmpty { await Task.yield() }
        let second = Task { try await approvals.authorize(credentialID: login, authorizationDeadline: now.addingTimeInterval(700),
            onProgress: { secondStatus.append($0) }) { Issue.record("Duplicate prompted") } }
        while secondStatus.isEmpty { await Task.yield() }
        #expect(firstStatus == secondStatus)
        #expect(secondStatus.first?.askedAt == now)
        authorizer.complete()
        try await first.value
        try await second.value
    }

    @Test("A locked Mac does not start authentication until unlock")
    func waitsForUnlock() async throws {
        let lock = FakeCredentialSessionLockState(isLocked: true)
        let now = Date(timeIntervalSince1970: 1_000)
        var prompts = 0
        var waits = 0
        var progress: [AgentApprovalProgress] = []
        let approvals = CredentialApprovalCoordinator(lockState: lock, now: { now }, sleep: { _ in
            #expect(prompts == 0)
            waits += 1
            lock.isLocked = false
        })
        try await approvals.authorize(credentialID: UUID(), authorizationDeadline: now.addingTimeInterval(600),
            onProgress: { progress.append($0) }) {
            #expect(!lock.isLocked)
            prompts += 1
        }
        #expect(waits == 1)
        #expect(prompts == 1)
        #expect(progress.map(\.phase) == [.waitingForUnlock, .awaitingApproval])
        #expect(progress.allSatisfy { $0.askedAt == now })
    }

    @Test("An unanswered locked request expires without starting authentication")
    func expiresWhileLocked() async throws {
        let lock = FakeCredentialSessionLockState(isLocked: true)
        var now = Date(timeIntervalSince1970: 1_000)
        let deadline = now.addingTimeInterval(600)
        let approvals = CredentialApprovalCoordinator(lockState: lock, now: { now }, sleep: { _ in
            now = deadline
        })
        await #expect(throws: CredentialReleaseAuthorizationError.expired) {
            try await approvals.authorize(credentialID: UUID(), authorizationDeadline: deadline) {
                Issue.record("Locked request started authentication")
            }
        }
    }

    @Test("Lock state comes from the session dictionary")
    func sessionDictionary() {
        #expect(SystemCredentialSessionLockState.isLocked(session: ["CGSSessionScreenIsLocked": true]))
        #expect(!SystemCredentialSessionLockState.isLocked(session: ["CGSSessionScreenIsLocked": false]))
        #expect(!SystemCredentialSessionLockState.isLocked(session: [:]))
        #expect(SystemCredentialSessionLockState.isLocked(session: nil))
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

@MainActor
final class FakeCredentialSessionLockState: CredentialSessionLockState {
    var isLocked: Bool

    init(isLocked: Bool = false) { self.isLocked = isLocked }
}
