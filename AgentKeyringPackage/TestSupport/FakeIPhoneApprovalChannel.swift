import AgentKeyringFeature
import Foundation

@MainActor
public final class FakeIPhoneApprovalChannel: IPhoneApprovalChannel {
    public private(set) var requests: [ApprovalRequest] = []
    public private(set) var cancelledRequestIDs: [UUID] = []
    private var continuations: [UUID: AsyncThrowingStream<ApprovalDecision, Error>.Continuation] = [:]

    public init() {}

    public func publish(_ request: ApprovalRequest) -> AsyncThrowingStream<ApprovalDecision, Error> {
        requests.append(request)
        let (stream, continuation) = AsyncThrowingStream<ApprovalDecision, Error>.makeStream()
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
