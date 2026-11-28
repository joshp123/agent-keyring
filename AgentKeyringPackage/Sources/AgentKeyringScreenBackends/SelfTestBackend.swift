// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The practice request in the card beside the window, laid out as a real one:
// first run's step 1, or one sent to this Mac from Devices.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
@MainActor
public final class SelfTestBackend: MacApprovalBackend {
    public static let requestID = "agent-keyring-self-test"
    private let model: MacKeyringEngine
    private var context: LAContext?

    public init(model: MacKeyringEngine) {
        self.model = model
    }

    public var request: AccessRequest {
        // First run's own practice, or one sent from Devices.
        let state: AccessRequestState = switch (model.firstRun.waitingPractice, model.practiceResults[model.thisMacDeviceKey]) {
        case (.some, _), (_, .sent?): .waitingForYou(until: .distantFuture)
        case let (_, .denied(_, reply)?): .denied(by: .mac, reply: reply.isEmpty ? nil : reply, askAgainAfter: nil)
        default:
            if case let .denied(reply) = model.firstRun.practice {
                .denied(by: .mac, reply: reply.isEmpty ? nil : reply, askAgainAfter: nil)
            } else {
                .approved(by: .mac, until: model.testedAt ?? .now)
            }
        }
        return .practiceAccessRequest(id: Self.requestID, state: state)
    }

    public func accessRequestUpdates(requestID: String) -> AsyncStream<AccessRequest> {
        streamUntilFinal(Observations { [weak self] in self?.request })
    }

    public func approveAccessRequest(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        // The request he clicked on: a late Touch ID answers only that one.
        let practice = model.firstRun.waitingPractice
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        do {
            try await model.runSelfTest(reason: MessageCopy.practiceInDialog, context: context, onAuthenticated: onAuthenticated)
            if let practice { model.sendFirstRunEvent(.practiceApproved(id: practice)) }
            model.notePracticeHere(.approved(at: .now))
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
        return request.state
    }

    public func cancelAuthentication(requestID: String) {
        context?.invalidate()
        context = nil
    }

    public func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState {
        cancelAuthentication(requestID: requestID)
        if let practice = model.firstRun.waitingPractice { model.sendFirstRunEvent(.practiceDenied(id: practice, reply: reply ?? "")) }
        model.notePracticeHere(.denied(at: .now, reply: reply ?? ""))
        return request.state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { request.state }
}
#endif
