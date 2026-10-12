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
        let leaseMonitorTask = Task { @MainActor [weak self] in
            if let self {
                await self.monitorAgentRequestLease(agentRequest)
            }
        }

        let fillDestination = agentRequest.action == .fill ? NSWorkspace.shared.frontmostApplication : nil
        do {
            try await authorizer.authorize(approval, onPromptStarted: onPromptStarted)
        } catch {
            await stopApprovalTasks(leaseMonitorTask)
            let requestIsLive = agentRequestIsLive(agentRequest)
            if !requestIsLive {
                throw CredentialReleaseAuthorizationError.expired
            }
            throw error
        }
        await stopApprovalTasks(leaseMonitorTask)
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

    private func stopApprovalTasks(
        _ leaseMonitorTask: Task<Void, Never>
    ) async {
        leaseMonitorTask.cancel()
        await leaseMonitorTask.value
    }

    private func monitorAgentRequestLease(_ request: AgentBridgeRequest) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if !agentRequestIsLive(request) {
                authorizer.cancelCurrentAuthorization()
                return
            }
        }
    }

    private func agentRequestIsLive(_ request: AgentBridgeRequest) -> Bool {
        request.expiresAt > Date()
            && bridge.requestMatches(request)

    }
}
