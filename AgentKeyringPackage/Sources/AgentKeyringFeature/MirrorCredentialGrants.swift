import AppKit
import Foundation

@available(macOS 26.0, *)
extension MirrorAppModel {
    public func endAllGrants() {
        grants.endAll()
    }

    func authorizeCredentialRelease(
        _ approval: CredentialReleaseAuthorizationRequest,
        agentRequest: AgentBridgeRequest,
        onPromptStarted: @escaping () -> Void
    ) async throws {
        let fillDestination = agentRequest.action == .fill ? NSWorkspace.shared.frontmostApplication : nil
        try await authorizer.authorize(approval, onPromptStarted: onPromptStarted)
        if let fillDestination,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            fillDestination.activate(options: [])
            let deadline = Date().addingTimeInterval(1)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != fillDestination.processIdentifier,
                Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

}
