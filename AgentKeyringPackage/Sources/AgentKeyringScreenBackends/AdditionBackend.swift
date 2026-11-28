// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Adding a computer or a device is a request
// in the same panel and with the same click and Touch ID as a password request
// (Paper, "First run", "Other computers, iPhone and Apple Watch").

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
@MainActor
public final class AdditionBackend: MacApprovalBackend {
    private let model: MacKeyringEngine
    private var contexts: [String: LAContext] = [:]

    public init(model: MacKeyringEngine) {
        self.model = model
    }

    /// Pure read of the join under this id from `joinHistory` and `filling`, with no cache mutations.
    public func accessRequest(_ id: String) -> AccessRequest? {
        guard let device = model.device,
              let summary = device.joinHistory.first(where: { $0.id == id }) else { return nil }
        let state: AccessRequestState
        var approvedProgress = ""
        switch summary.state {
        case .waiting:
            state = .waitingForYou(until: summary.asked.addingTimeInterval(600))
        case .approved:
            state = .approved(by: .mac, until: .now)
            if let filling = device.filling, filling.deviceKeyID == id {
                approvedProgress = filling.failure.map {
                    SetupCopy.stoppedCopying(done: filling.done, total: filling.total, reason: $0)
                } ?? SetupCopy.copyingTo(done: filling.done, total: filling.total)
            }
        case .refused:
            state = .denied(by: .mac, reply: summary.refusalReply, askAgainAfter: nil)
        case .expired:
            state = .unanswered
        case .withdrawn:
            state = .cancelled
        default:
            state = .unanswered
        }

        switch summary.joiner {
        case let .device(kind):
            return AccessRequest(
                id: id,
                login: RequestedLogin(site: summary.label, account: ""),
                agent: RequestingAgent(name: summary.label, machine: summary.label, address: "", isLocal: false),
                access: .setUp(
                    lead: kind == .watch ? SetupCopy.addWatchLead : SetupCopy.addIPhoneLead,
                    detail: kind == .watch ? SetupCopy.addWatchBody : SetupCopy.addIPhoneBody,
                    footer: "",
                    denied: SetupCopy.notAdded(summary.label),
                    replies: false,
                    approved: approvedProgress
                ),
                agentReason: "",
                askedAt: summary.asked,
                state: state
            )
        case .computer:
            return AccessRequest(
                id: id,
                login: RequestedLogin(site: summary.label, account: ""),
                agent: RequestingAgent(name: "An agent", machine: summary.label, address: "", isLocal: false),
                access: .setUp(
                    lead: SetupCopy.addComputerLead,
                    detail: SetupCopy.addComputerBody,
                    footer: "",
                    denied: SetupCopy.notAdded(summary.label),
                    replies: summary.replies,
                    approved: approvedProgress
                ),
                agentReason: "",
                askedAt: summary.asked,
                state: state
            )
        }
    }

    public func accessRequestUpdates(requestID: String) -> AsyncStream<AccessRequest> {
        streamUntilFinal(Observations { [weak self] in self?.accessRequest(requestID) })
    }

    public func approveAccessRequest(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        guard let device = model.device else { throw ScreenFailure(message: MessageCopy.noKeysYet) }
        let context = LAContext()
        contexts[requestID] = context
        defer {
            if contexts[requestID] === context { contexts[requestID] = nil }
            context.invalidate()
        }
        do {
            try await screenErrors {
                try await device.approveJoin(requestID, context: context, onAuthenticated: onAuthenticated)
            }
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
        return accessRequest(requestID)?.state ?? .approved(by: .mac, until: .now)
    }

    public func cancelAuthentication(requestID: String) {
        contexts.removeValue(forKey: requestID)?.invalidate()
    }

    public func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState {
        cancelAuthentication(requestID: requestID)
        let told = model.device?.refuseJoin(requestID, reply: reply ?? "") ?? false
        return accessRequest(requestID)?.state ?? .denied(by: .mac, reply: told ? reply : nil, askAgainAfter: nil)
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        accessRequest(requestID)?.state ?? .unanswered
    }
}
#endif
