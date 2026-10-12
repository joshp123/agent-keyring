import CloudKit
import Foundation
import OSLog

private let cloudApprovalLogger = Logger(subsystem: "com.agentkeyring.app", category: "CloudApproval")

@MainActor
public final class CloudKitIPhoneApprovalChannel: IPhoneApprovalChannel {
    private let database: any ApprovalCloudDatabase
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var publications: [UUID: Task<Void, Never>] = [:]

    public init(database: any ApprovalCloudDatabase = PrivateApprovalCloudDatabase(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.database = database
        self.now = now
        self.sleep = sleep
    }

    public func publish(_ request: ApprovalRequest) -> AsyncThrowingStream<ApprovalDecision, Error> {
        let (stream, continuation) = AsyncThrowingStream<ApprovalDecision, Error>.makeStream()
        publications[request.id] = Task { @MainActor in
            var failure: (any Error)?
            do {
                try Task.checkCancellation()
                if self.now().timeIntervalSince1970 < Double(request.expiresAt) {
                    try await self.database.save(ApprovalCloudRecords.request(request))
                    while self.now().timeIntervalSince1970 < Double(request.expiresAt) {
                        try Task.checkCancellation()
                        try await self.sleep(.seconds(2))
                        try Task.checkCancellation()
                        guard self.now().timeIntervalSince1970 < Double(request.expiresAt) else { break }
                        do {
                            let record = try await self.database.fetch(ApprovalCloudRecords.decisionID(request.id))
                            try Task.checkCancellation()
                            guard self.now().timeIntervalSince1970 < Double(request.expiresAt) else { break }
                            if let record, let decision = ApprovalCloudRecords.decision(from: record, for: request) {
                                continuation.yield(decision)
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch let error as CKError where error.code == .notAuthenticated || error.code == .quotaExceeded {
                            throw error
                        } catch {
                            cloudApprovalLogger.error("Approval polling failed; retrying until request expiry.")
                        }
                    }
                }
            } catch is CancellationError { /* Normal request cancellation. */ }
            catch { failure = IPhoneApprovalFailure(cloudError: error) }

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

    public func cancel(requestID: UUID) {
        publications[requestID]?.cancel()
    }

    public func waitForCleanup(requestID: UUID) async {
        guard let task = publications[requestID] else { return }
        await task.value
        publications.removeValue(forKey: requestID)
    }
}
