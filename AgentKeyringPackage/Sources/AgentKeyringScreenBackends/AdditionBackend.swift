// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Adding the always-on machine, another machine or a device is a request in
// the same panel and with the same click and touch as a login request
// (Paper, "First run", steps 3 and 5).

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
            return request
        }
        guard let device = model.device else { return nil }
        let request: AccessRequest?
        if id == Self.setupID, let setup = device.setup, let machine = setup.machine {
            request = AccessRequest(id: id, login: RequestedLogin(site: machine.label, account: ""),
                agent: RequestingAgent(name: setup.agent, machine: "This Mac", address: "", isLocal: true),
                access: .setUp(lead: "\(setup.agent) on this Mac wants to add", detail: "as your always-on machine",
                    footer: "Agents on \(machine.label) can then ask to use your logins. You can remove it at any time."),
                agentReason: setup.reason, askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
        } else if let join = device.joins.first(where: { MacDevice.joinID($0) == id }) {
            let asked = Date(timeIntervalSince1970: TimeInterval(join.askedUnixSeconds))
            switch join.request.joining {
            case let .device(joining)?:
                request = AccessRequest(id: id, login: RequestedLogin(site: joining.label, account: ""),
                    agent: RequestingAgent(name: joining.label, machine: joining.label, address: "", isLocal: false),
                    access: .setUp(lead: "A new device wants to approve requests", detail: joining.kind == .watch
                        ? "Paired with your iPhone" : "Signed in to your Apple Account",
                        footer: joining.kind == .watch ? "It will approve when it is on your wrist and unlocked. You can remove it at any time."
                            : "It will approve with Face ID. You can remove it at any time."),
                    agentReason: "", askedAt: asked, state: .waitingForYou(until: asked.addingTimeInterval(600)))
            case let .machine(machine)?:
                request = AccessRequest(id: id, login: RequestedLogin(site: machine.label, account: ""),
                    agent: RequestingAgent(name: "An agent", machine: machine.label, address: "", isLocal: false),
                    access: .setUp(lead: "An agent wants to add", detail: "as a machine that asks for your logins",
                        footer: "Agents on \(machine.label) can then ask to use your logins. You can remove it at any time."),
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
        guard let device = model.device else { throw ScreenFailure(message: "This Mac has no keys yet.") }
        let context = LAContext()
        contexts[requestID] = context
        defer { if contexts[requestID] === context { contexts[requestID] = nil } }
        do {
            try await screenErrors {
                if requestID == Self.setupID {
                    try await device.confirmSetup(context: context, onAuthenticated: onAuthenticated)
                    await model.reportLastSelfTest()
                } else {
                    try await device.approveJoin(requestID, allowAutomatic: false, context: context, onAuthenticated: onAuthenticated)
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
        if requestID == Self.setupID { model.device?.abandonSetup() } else { model.device?.hideJoin(requestID) }
        let state = AccessRequestState.denied(by: .mac, reply: nil, askAgainAfter: nil)
        answered[requestID] = state
        return state
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { answered[requestID] ?? .unanswered }
}
#endif
