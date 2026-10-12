import Foundation
import OSLog

public struct AgentRequestActivity: Sendable {
    public let requestID: UUID
    public let action: AgentBridgeAction
    public let requester: AgentRequester
    public let completedAt: Date
    public let succeeded: Bool
    public let error: AgentBridgeErrorCode?

    func log(to logger: Logger) {
        let start = requester.processStartTime.map { "\($0.seconds).\($0.microseconds)" } ?? "unavailable"
        logger.info("Agent request \(requestID, privacy: .private) action=\(action.rawValue, privacy: .public) harness=\(requester.name, privacy: .private) pid=\(requester.processIdentifier, privacy: .private) started=\(start, privacy: .private) folder=\(requester.workingDirectory ?? "unavailable", privacy: .private) machine=\(requester.machineName, privacy: .private) address=\(requester.networkAddress ?? "unavailable", privacy: .private) success=\(succeeded, privacy: .public) error=\(error?.rawValue ?? "none", privacy: .public)")
    }
}
