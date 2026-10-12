import Foundation

@MainActor
final class HarnessSessionRequestQueue {
    private struct WaitingRequest {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let expiry: Task<Void, Never>
    }

    private var active: Set<HarnessSession> = []
    private var waiting: [HarnessSession: [WaitingRequest]] = [:]
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void

    init(now: @escaping () -> Date, sleep: @escaping (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    func waitingCount(for session: HarnessSession) -> Int { waiting[session]?.count ?? 0 }

    func withTurn<Result>(session: HarnessSession?, deadline: Date,
        operation: @MainActor () async throws -> Result) async throws -> Result {
        guard let session else { return try await operation() }
        try await acquire(session: session, deadline: deadline)
        defer { release(session: session) }
        try Task.checkCancellation()
        guard now() < deadline else { throw CredentialReleaseAuthorizationError.expired }
        return try await operation()
    }

    private func acquire(session: HarnessSession, deadline: Date) async throws {
        try Task.checkCancellation()
        guard now() < deadline else { throw CredentialReleaseAuthorizationError.expired }
        if active.insert(session).inserted { return }
        let requestID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let expiry = Task { @MainActor in
                    do {
                        try await self.sleep(.seconds(max(0, deadline.timeIntervalSince(self.now()))))
                        guard !Task.isCancelled else { return }
                        self.removeWaiting(session: session, requestID: requestID,
                            error: CredentialReleaseAuthorizationError.expired)
                    } catch { }
                }
                waiting[session, default: []].append(WaitingRequest(id: requestID,
                    continuation: continuation, expiry: expiry))
            }
        } onCancel: {
            Task { @MainActor in
                self.removeWaiting(session: session, requestID: requestID, error: CancellationError())
            }
        }
    }

    private func removeWaiting(session: HarnessSession, requestID: UUID, error: Error) {
        guard var requests = waiting[session], let index = requests.firstIndex(where: { $0.id == requestID }) else { return }
        let request = requests.remove(at: index)
        waiting[session] = requests.isEmpty ? nil : requests
        request.expiry.cancel()
        request.continuation.resume(throwing: error)
    }

    private func release(session: HarnessSession) {
        guard var requests = waiting[session], !requests.isEmpty else {
            active.remove(session)
            return
        }
        let request = requests.removeFirst()
        waiting[session] = requests.isEmpty ? nil : requests
        request.expiry.cancel()
        request.continuation.resume()
    }
}
