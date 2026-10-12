import Foundation

/// Publishes the Mac's retained request and returns signed decisions for routing to verify.
@MainActor
public protocol IPhoneApprovalChannel {
    func publish(_ request: ApprovalRequest) -> AsyncThrowingStream<ApprovalDecision, Error>
    func cancel(requestID: UUID)
    func waitForCleanup(requestID: UUID) async
}

public extension IPhoneApprovalChannel {
    func waitForCleanup(requestID: UUID) async {}
}
