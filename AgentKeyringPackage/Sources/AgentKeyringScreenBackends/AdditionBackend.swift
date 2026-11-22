// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Adding a computer or a device is a request
// in the same panel and with the same click and Touch ID as a password request
// (Paper, "First run", "Other computers, iPhone and Apple Watch").

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
@MainActor
public final class AdditionBackend: MacApprovalBackend {
    private let model: MirrorAppModel
    private var contexts: [String: LAContext] = [:]
    private var answered: [String: AccessRequestState] = [:]

    public init(model: MirrorAppModel) {
        self.model = model
    }

    /// The join waiting under this id, as the panel shows it.
    public func request(_ id: String) -> AccessRequest? {
        guard let device = model.device else { return nil }
        // Check active waiting joins FIRST so a device that was previously denied or removed
        // and joins again in the same app session is never masked by a stale cached answer.
        if let join = device.joins.first(where: { MacDevice.joinID($0) == id }) {
            answered.removeValue(forKey: id)
            let asked = Date(timeIntervalSince1970: TimeInterval(join.askedUnixSeconds))
            let request: AccessRequest?
            switch join.request.joining {
            case let .device(joining)?:
                request = AccessRequest(id: id, login: RequestedLogin(site: joining.label, account: ""),
                    agent: RequestingAgent(name: joining.label, machine: joining.label, address: "", isLocal: false),
                    access: .setUp(lead: joining.kind == .watch ? SetupCopy.addWatchLead : SetupCopy.addIPhoneLead,
                        detail: joining.kind == .watch ? SetupCopy.addWatchBody : SetupCopy.addIPhoneBody,
                        footer: "", denied: SetupCopy.notAdded(joining.label), replies: false),
                    agentReason: "", askedAt: asked, state: .waitingForYou(until: asked.addingTimeInterval(600)))
            case let .machine(machine)?:
                request = AccessRequest(id: id, login: RequestedLogin(site: machine.label, account: ""),
                    agent: RequestingAgent(name: "An agent", machine: machine.label, address: "", isLocal: false),
                    access: .setUp(lead: SetupCopy.addComputerLead, detail: SetupCopy.addComputerBody,
                        footer: "", denied: SetupCopy.notAdded(machine.label), replies: !join.request.refusalKeySha256.isEmpty),
                    agentReason: "", askedAt: asked, state: .waitingForYou(until: asked.addingTimeInterval(600)))
            case nil: request = nil
            }
            if let request { lastShown[id] = request }
            return request
        }
        if let state = answered[id], let last = lastShown[id] {
            var request = last
            request.state = state
            // A new device is being given its copies: the panel says how far, and stays until it is done.
            if let filling = model.device?.filling, filling.deviceKeyID == id,
               case let .setUp(lead, detail, footer, denied, replies, _) = last.access {
                request.access = .setUp(lead: lead, detail: detail, footer: footer, denied: denied, replies: replies,
                    approved: filling.failure.map { SetupCopy.stoppedCopying(done: filling.done, total: filling.total, reason: $0) }
                        ?? SetupCopy.copyingTo(done: filling.done, total: filling.total))
            }
            return request
        }
        return nil
    }

    private var lastShown: [String: AccessRequest] = [:]

    public func updates(requestID: String) -> AsyncStream<AccessRequest> {
        streamUntilFinal(Observations { [weak self] in self?.request(requestID) })
    }

    public func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        guard let device = model.device else { throw ScreenFailure(message: MessageCopy.noKeysYet) }
        let context = LAContext()
        contexts[requestID] = context
        defer { if contexts[requestID] === context { contexts[requestID] = nil } }
        do {
            try await screenErrors {
                try await device.approveJoin(requestID, context: context, onAuthenticated: onAuthenticated)
            }
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
        let state = AccessRequestState.approved(by: .mac, until: .now)
        answered[requestID] = state
        return state
    }

    public func cancelAuthentication(requestID: String) {
        contexts.removeValue(forKey: requestID)?.invalidate()
    }

    public func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        cancelAuthentication(requestID: requestID)
        let told = model.device?.refuseJoin(requestID, reply: reply ?? "") ?? false
        // The words show as sent only if the waiting agent will get them.
        let state = AccessRequestState.denied(by: .mac, reply: told ? reply : nil, askAgainAfter: nil)
        answered[requestID] = state
        return state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { answered[requestID] ?? .unanswered }
}
#endif
