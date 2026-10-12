import Foundation

/// Publishes the Mac's request and returns signed decisions. The transport is a fake for now.
@MainActor
public protocol IPhoneApprovalChannel {
    func publish(_ request: ApprovalRequest) -> AsyncStream<ApprovalDecision>
    func cancel(requestID: UUID)
}
