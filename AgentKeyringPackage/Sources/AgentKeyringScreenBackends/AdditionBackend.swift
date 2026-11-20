// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Adding the computer that stays on, another computer or a device is a request
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
    public static let setupID = "agent-keyring-setup"
    private let model: MirrorAppModel
    private var contexts: [String: LAContext] = [:]
    private var answered: [String: AccessRequestState] = [:]

    public init(model: MirrorAppModel) {
        self.model = model
    }

    /// The setup or join waiting under this id, as the panel shows it.
    public func request(_ id: String) -> AccessRequest? {
        if let state = answered[id], let last = lastShown[id] {
            var request = last
            request.state = state
            // A new device is being given its copies: the panel says how far, and stays until it is done.
            if let filling = model.device?.filling, filling.deviceKeyID == id,
               case let .setUp(lead, detail, footer, denied, replies, _) = last.access {
                request.access = .setUp(lead: lead, detail: detail, footer: footer, denied: denied, replies: replies,
                    approved: filling.failure.map { SetupCopy.fillingStopped(filling.label, reason: $0) }
                        ?? SetupCopy.filling(filling.label, done: filling.done, total: filling.total))
            }
            return request
        }
        guard let device = model.device else { return nil }
        let request: AccessRequest?
        if id == Self.setupID, let setup = device.setup, let machine = setup.machine {
            request = AccessRequest(id: id, login: RequestedLogin(site: machine.label, account: ""),
                agent: RequestingAgent(name: setup.agent, machine: "This Mac", address: "", isLocal: true),
                access: .setUp(lead: SetupCopy.addingComputerLead(agent: setup.agent), detail: "",
                    footer: SetupCopy.addingComputerFooter(machine.label, staysOn: true), denied: SetupCopy.notAdded(machine.label),
                    replies: setup.refusable),
                agentReason: setup.reason, askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
        } else if let join = device.joins.first(where: { MacDevice.joinID($0) == id }) {
            let asked = Date(timeIntervalSince1970: TimeInterval(join.askedUnixSeconds))
            switch join.request.joining {
            case let .device(joining)?:
                request = AccessRequest(id: id, login: RequestedLogin(site: joining.label, account: ""),
                    agent: RequestingAgent(name: joining.label, machine: joining.label, address: "", isLocal: false),
                    access: .setUp(lead: SetupCopy.addingDeviceLead,
                        detail: SetupCopy.addingDeviceDetail(watch: joining.kind == .watch),
                        footer: SetupCopy.addingDeviceFooter(watch: joining.kind == .watch), denied: SetupCopy.notAdded(joining.label),
                        replies: false),
                    agentReason: "", askedAt: asked, state: .waitingForYou(until: asked.addingTimeInterval(600)))
            case let .machine(machine)?:
                request = AccessRequest(id: id, login: RequestedLogin(site: machine.label, account: ""),
                    agent: RequestingAgent(name: "An agent", machine: machine.label, address: "", isLocal: false),
                    access: .setUp(lead: SetupCopy.addingLead, detail: "",
                        footer: SetupCopy.addingComputerFooter(machine.label, staysOn: false), denied: SetupCopy.notAdded(machine.label),
                        replies: !join.request.refusalKeySha256.isEmpty),
                    agentReason: "", askedAt: asked, state: .waitingForYou(until: asked.addingTimeInterval(600)))
            case nil: request = nil
            }
        } else {
            request = nil
        }
        if let request { lastShown[id] = request }
        return request
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
                if requestID == Self.setupID {
                    try await device.confirmSetup(thisMacAutomatic: model.automaticOnThisMac, context: context,
                        onAuthenticated: onAuthenticated)
                    await model.reportLastSelfTest()
                } else {
                    try await device.approveJoin(requestID, context: context, onAuthenticated: onAuthenticated)
                }
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
        let told = requestID == Self.setupID
            ? await model.device?.refuseSetup(reply: reply ?? "") ?? false
            : await model.device?.refuseJoin(requestID, reply: reply ?? "") ?? false
        // The words show as sent only if the waiting agent will get them.
        let state = AccessRequestState.denied(by: .mac, reply: told ? reply : nil, askAgainAfter: nil)
        answered[requestID] = state
        return state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { answered[requestID] ?? .unanswered }
}
#endif
