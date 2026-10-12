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
        let first = Task { try await approvals.authorize(credentialID: login, authorizationDeadline: request.authorizationDeadline) { try await authorizer.authorize(request, onPromptStarted: $0) } }
        while authorizer.requests.isEmpty { await Task.yield() }
        let second = Task { try await approvals.authorize(credentialID: login, authorizationDeadline: request.authorizationDeadline) { try await authorizer.authorize(request, onPromptStarted: $0) } }
        for _ in 0..<20 { await Task.yield() }
        #expect(authorizer.requests.count == 1)
        authorizer.complete(error: .denied)
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await first.value }
        await #expect(throws: CredentialReleaseAuthorizationError.denied) { try await second.value }
        var retried = false
        try await approvals.authorize(credentialID: login, authorizationDeadline: request.authorizationDeadline) { onPromptStarted in onPromptStarted(); retried = true }
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
            onProgress: { firstStatus.append($0) }) { try await authorizer.authorize(request, onPromptStarted: $0) } }
        while authorizer.requests.isEmpty { await Task.yield() }
        let second = Task { try await approvals.authorize(credentialID: login, authorizationDeadline: now.addingTimeInterval(700),
            onProgress: { secondStatus.append($0) }) { _ in Issue.record("Duplicate prompted") } }
        while secondStatus.isEmpty { await Task.yield() }
        #expect(firstStatus.last == secondStatus.first)
        #expect(secondStatus.first?.askedAt == now)
        authorizer.complete()
        try await first.value
        try await second.value
    }

    @Test("Joiners keep their own deadline after the shared approval expires", arguments: [false, true])
    func joinedApprovalExpiry(joinerAlsoExpired: Bool) async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let firstDeadline = now.addingTimeInterval(60)
        let joinerDeadline = now.addingTimeInterval(120)
        let approvals = CredentialApprovalCoordinator(lockState: FakeCredentialSessionLockState(), now: { now })
        let authorizer = FakeCredentialAuthorizer()
        let login = UUID()
        var joinerStatus: [AgentApprovalProgress] = []
        let first = Task {
            try await approvals.authorize(credentialID: login, authorizationDeadline: firstDeadline) {
                try await authorizer.authorize(CredentialReleaseAuthorizationRequest(destination: "example.com",
                    account: "synthetic", field: .password, authorizationDeadline: firstDeadline), onPromptStarted: $0)
            }
        }
        while authorizer.requests.isEmpty { await Task.yield() }
        let joiner = Task {
            try await approvals.authorize(credentialID: login, authorizationDeadline: joinerDeadline,
                onProgress: { joinerStatus.append($0) }) {
                    try await authorizer.authorize(CredentialReleaseAuthorizationRequest(destination: "example.com",
                        account: "synthetic", field: .password, authorizationDeadline: joinerDeadline), onPromptStarted: $0)
                }
        }
        while joinerStatus.isEmpty { await Task.yield() }
        #expect(authorizer.requests.count == 1)
        now = joinerAlsoExpired ? joinerDeadline : firstDeadline
        authorizer.complete(error: .expired)
        await #expect(throws: CredentialReleaseAuthorizationError.expired) { try await first.value }
        if joinerAlsoExpired {
            await #expect(throws: CredentialReleaseAuthorizationError.expired) { try await joiner.value }
            #expect(authorizer.requests.count == 1)
        } else {
            while authorizer.requests.count < 2 { await Task.yield() }
            #expect(authorizer.requests.last?.authorizationDeadline == joinerDeadline)
            #expect(joinerStatus.last?.askedAt == firstDeadline)
            authorizer.complete()
            try await joiner.value
        }
    }

    @Test("Different logins woken by the same unlock serialize window setup and authentication")
    func serialApprovalsAfterUnlock() async throws {
        let lock = FakeCredentialSessionLockState(isLocked: true)
        let approvals = CredentialApprovalCoordinator(lockState: lock, sleep: { _ in
            while lock.isLocked { await Task.yield() }
        })
        let authorizer = FakeCredentialAuthorizer()
        var queued = 0
        var presented: [String] = []
        var finishFirstWindowSetup: CheckedContinuation<Void, Never>?
        func start(_ account: String) -> Task<Void, Error> {
            Task {
                try await approvals.authorize(credentialID: UUID(), authorizationDeadline: Date().addingTimeInterval(600),
                    onProgress: { _ in queued += 1 }) { onPromptStarted in
                        presented.append(account)
                        if account == "first" {
                            await withCheckedContinuation { finishFirstWindowSetup = $0 }
                        }
                        try await authorizer.authorize(CredentialReleaseAuthorizationRequest(
                            destination: "example.com", account: account, field: .password), onPromptStarted: onPromptStarted)
                    }
            }
        }
        let first = start("first")
        while queued == 0 { await Task.yield() }
        let second = start("second")
        while queued < 2 { await Task.yield() }
        lock.isLocked = false
        while finishFirstWindowSetup == nil { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(presented == ["first"])
        #expect(authorizer.requests.isEmpty)
        finishFirstWindowSetup?.resume()
        while authorizer.requests.isEmpty { await Task.yield() }
        #expect(presented == ["first"])
        authorizer.complete()
        try await first.value
        while authorizer.requests.count < 2 { await Task.yield() }
        #expect(presented == ["first", "second"])
        #expect(authorizer.requests.map(\.account) == ["first", "second"])
        authorizer.complete()
        try await second.value
    }

    @Test("A locked Mac does not start authentication until unlock")
    func waitsForUnlock() async throws {
        let lock = FakeCredentialSessionLockState(isLocked: true)
        var now = Date(timeIntervalSince1970: 1_000)
        let waitingSince = now
        var prompts = 0
        var waits = 0
        var progress: [AgentApprovalProgress] = []
        let approvals = CredentialApprovalCoordinator(lockState: lock, now: { now }, sleep: { _ in
            #expect(prompts == 0)
            waits += 1
            now = now.addingTimeInterval(60)
            lock.isLocked = false
        })
        try await approvals.authorize(credentialID: UUID(), authorizationDeadline: now.addingTimeInterval(600),
            onProgress: { progress.append($0) }) { onPromptStarted in
            #expect(!lock.isLocked)
            #expect(progress.last?.askedAt == nil)
            now = now.addingTimeInterval(5)
            onPromptStarted()
            prompts += 1
        }
        #expect(waits == 1)
        #expect(prompts == 1)
        #expect(progress.map(\.phase) == [.waitingForUnlock, .awaitingApproval])
        #expect(progress.first?.askedAt == nil)
        #expect(progress.last?.askedAt == now)
        #expect(progress.allSatisfy { $0.waitingSince == waitingSince })
    }

    @Test("An unlocked request records when authentication starts, after setup")
    func promptStartTime() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let waitingSince = now
        let approvals = CredentialApprovalCoordinator(lockState: FakeCredentialSessionLockState(), now: { now })
        var progress: [AgentApprovalProgress] = []
        try await approvals.authorize(credentialID: UUID(), authorizationDeadline: now.addingTimeInterval(600),
            onProgress: { progress.append($0) }) { onPromptStarted in
                #expect(progress.count == 1)
                #expect(progress.first?.askedAt == nil)
                now = now.addingTimeInterval(5)
                onPromptStarted()
            }
        #expect(progress.count == 2)
        #expect(progress.last?.askedAt == now)
        #expect(progress.last?.waitingSince == waitingSince)
    }

    @Test("Failed prompt setup never records that the owner was asked")
    func failedPromptSetup() async throws {
        let approvals = CredentialApprovalCoordinator(lockState: FakeCredentialSessionLockState())
        var progress: [AgentApprovalProgress] = []
        await #expect(throws: CredentialReleaseAuthorizationError.unavailable) {
            try await approvals.authorize(credentialID: UUID(), authorizationDeadline: Date().addingTimeInterval(600),
                onProgress: { progress.append($0) }) { _ in
                    throw CredentialReleaseAuthorizationError.unavailable
                }
        }
        #expect(progress.count == 1)
        #expect(progress.first?.askedAt == nil)
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
            try await approvals.authorize(credentialID: UUID(), authorizationDeadline: deadline) { _ in
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

    func authorize(_ request: CredentialReleaseAuthorizationRequest, onPromptStarted: @escaping () -> Void) async throws {
        requests.append(request)
        onPromptStarted()
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
