import AgentKeyringFeature
import Foundation

@MainActor
public final class FakeIPhoneApprovalChannel: IPhoneApprovalChannel {
    public private(set) var requests: [ApprovalRequest] = []
    public private(set) var cancelledRequestIDs: [UUID] = []
    private var continuations: [UUID: AsyncStream<ApprovalDecision>.Continuation] = [:]

    public init() {}

    public func publish(_ request: ApprovalRequest) -> AsyncStream<ApprovalDecision> {
        requests.append(request)
        let (stream, continuation) = AsyncStream<ApprovalDecision>.makeStream()
        continuations[request.id] = continuation
        return stream
    }

    public func answer(_ decision: ApprovalDecision) {
        answer(decision, on: decision.requestID)
    }

    public func answer(_ decision: ApprovalDecision, on requestID: UUID) {
        continuations[requestID]?.yield(decision)
    }

    public func cancel(requestID: UUID) {
        cancelledRequestIDs.append(requestID)
        continuations.removeValue(forKey: requestID)?.finish()
    }
}
