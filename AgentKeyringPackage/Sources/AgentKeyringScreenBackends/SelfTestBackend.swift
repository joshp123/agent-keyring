// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// First run's practice request in the request panel, laid out as a real one
// (Paper, "First run", "When the passwords arrive").

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
        let state: AccessRequestState = switch model.firstRun {
        case .practice: .waitingForYou(until: .distantFuture)
        case let .practiceDenied(reply): .denied(by: .mac, reply: reply.isEmpty ? nil : reply, askAgainAfter: nil)
        default: .approved(by: .mac, until: model.testedAt ?? .now)
        }
        return .practice(id: Self.requestID, state: state)
    }

    public func updates(requestID: String) -> AsyncStream<AccessRequest> {
        streamUntilFinal(Observations { [weak self] in self?.request })
    }

    public func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        do {
            try await model.runSelfTest(reason: FirstRunCopy.practiceReasonInDialog, context: context, onAuthenticated: onAuthenticated)
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
        model.send(.practiceDenied(reply: reply ?? ""))
        return request.state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { request.state }
}
#endif
