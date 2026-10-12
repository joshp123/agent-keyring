import AgentKeyringFeature
import Foundation

@MainActor
public func sendTestAgentRequest(_ request: AgentBridgeRequest, model: MirrorAppModel,
    bridge: AgentBridgeDirectory) async throws -> AgentBridgeResponse {
    try model.startAgentListener()
    return try await AgentBridgeClient(bridge: bridge).send(request) { _ in
        throw AgentBridgeFailure(.bridgeUnavailable, "The test listener should already be running.")
    }
}
