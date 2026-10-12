import Foundation
import OSLog

private let cloudApprovalLogger = Logger(subsystem: "com.agentkeyring.app", category: "CloudApproval")

@MainActor
public final class CloudKitIPhoneApprovalChannel: IPhoneApprovalChannel {
    private final class PendingPublication {
        var task: Task<Void, Never>?
        var sleepTask: Task<Void, Error>?
    }

    private let database: any ApprovalCloudDatabase
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var publications: [UUID: PendingPublication] = [:]

    public init(database: any ApprovalCloudDatabase = PrivateApprovalCloudDatabase(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.database = database
        self.now = now
        self.sleep = sleep
    }

    public func publish(_ request: ApprovalRequest) -> AsyncThrowingStream<ApprovalDecision, Error> {
        let (stream, continuation) = AsyncThrowingStream<ApprovalDecision, Error>.makeStream()
        let publication = PendingPublication()
        publications[request.id] = publication
        publication.task = Task { @MainActor in
            var failure: (any Error)?
            do {
                try Task.checkCancellation()
                if self.now().timeIntervalSince1970 < Double(request.expiresAt) {
                    try await self.database.save(ApprovalCloudRecords.request(request))
                    while self.now().timeIntervalSince1970 < Double(request.expiresAt) {
                        try Task.checkCancellation()
                        let sleeper = Task { try await self.sleep(.seconds(2)) }
                        publication.sleepTask = sleeper
                        do {
                            try await withTaskCancellationHandler {
                                try await sleeper.value
                            } onCancel: { sleeper.cancel() }
                        } catch is CancellationError {
                            // A push cancels only this sleep; cancellation of the request ends polling.
                            try Task.checkCancellation()
                        }
                        publication.sleepTask = nil
                        try Task.checkCancellation()
                        guard self.now().timeIntervalSince1970 < Double(request.expiresAt) else { break }
                        let record = try await self.database.fetch(ApprovalCloudRecords.decisionID(request.id))
                        try Task.checkCancellation()
                        guard self.now().timeIntervalSince1970 < Double(request.expiresAt) else { break }
                        if let record, let decision = ApprovalCloudRecords.decision(from: record, for: request) {
                            continuation.yield(decision)
                        }
                    }
                }
            } catch is CancellationError { /* Normal request cancellation. */ }
            catch { failure = error }

            // A fresh task allows deletion even when the polling task was cancelled.
            await Task { @MainActor in
                for recordID in [ApprovalCloudRecords.requestID(request.id), ApprovalCloudRecords.decisionID(request.id)] {
                    do { try await self.database.delete(recordID) }
                    catch { cloudApprovalLogger.error("Approval record cleanup failed; remote expiry still applies.") }
                }
            }.value
            if let failure { continuation.finish(throwing: failure) }
            else { continuation.finish() }
        }
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { @MainActor in self.cancel(requestID: request.id) }
            }
        }
        return stream
    }

    /// Push contains no trusted decision. It only brings the next fetch forward.
    public func wakeUp(requestID: UUID) {
        publications[requestID]?.sleepTask?.cancel()
    }

    public func cancel(requestID: UUID) {
        publications[requestID]?.task?.cancel()
    }

    public func waitForCleanup(requestID: UUID) async {
        guard let publication = publications[requestID] else { return }
        await publication.task?.value
        publications.removeValue(forKey: requestID)
    }
}
