// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// First run's test request in the request panel (Paper, "First run", step 2).

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
@MainActor
public final class SelfTestBackend: MacApprovalBackend {
    public static let requestID = "agent-keyring-self-test"
    private let model: MirrorAppModel
    private var context: LAContext?

    public init(model: MirrorAppModel) {
        self.model = model
    }

    public var request: AccessRequest {
        let state: AccessRequestState = switch model.selfTest {
        case .waiting, .notRun: .waitingForYou(until: .distantFuture)
        case let .passed(at): .approved(by: .mac, until: at)
        case .failed: .denied(by: .mac, reply: nil, askAgainAfter: nil)
        }
        return AccessRequest(id: Self.requestID, login: RequestedLogin(site: "Test request", account: "No login is used"),
            agent: RequestingAgent(name: "Agent Keyring", machine: "This Mac", address: "", isLocal: true),
            access: .setUp(lead: "A test from Agent Keyring", detail: "No login is used", footer: "Approve it to finish setting up."),
            agentReason: "", askedAt: .now, state: state)
    }

    public func updates(requestID: String) -> AsyncStream<AccessRequest> {
        streamUntilFinal(Observations { [weak self] in self?.request })
    }

    public func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        do {
            try await model.runSelfTest(context: context, onAuthenticated: onAuthenticated)
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
        return request.state
    }

    public func cancelAuthentication(requestID: String) {
        context?.invalidate()
        context = nil
    }

    public func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        cancelAuthentication(requestID: requestID)
        model.declineSelfTest()
        return .denied(by: .mac, reply: nil, askAgainAfter: nil)
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { request.state }
}
#endif
