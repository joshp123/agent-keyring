// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Requests from agents on Josh's other computers in the Mac's usual panel,
// with the same click and Touch ID as this Mac's own (MacRemoteAsks.swift).
// Plumbing only: the request, its answer and its outcome are MacDevice's.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
@MainActor
public final class RemoteRequestBackend: MacApprovalBackend {
    private let model: MirrorAppModel
    private var contexts: [String: LAContext] = [:]

    public init(model: MirrorAppModel) {
        self.model = model
    }

    /// The request under this id, as the panel shows it; nil once it has gone.
    public func request(_ id: String) -> AccessRequest? {
        guard let device = model.device, let ask = device.remoteAsks[id] else { return nil }
        return Self.accessRequest(ask, members: device.members)
    }

    public func updates(requestID: String) -> AsyncStream<AccessRequest> {
        streamUntilFinal(Observations { [weak self] in self?.request(requestID) })
    }

    public func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        guard let device = model.device else { throw ScreenFailure(message: MessageCopy.noKeysYet) }
        let context = LAContext()
        contexts[requestID] = context
        defer { if contexts[requestID] === context { contexts[requestID] = nil } }
        do {
            let lease = try await device.approveRemote(requestID, context: context, onAuthenticated: onAuthenticated)
            return Self.state(lease, members: device.members)
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
    }

    public func cancelAuthentication(requestID: String) {
        contexts.removeValue(forKey: requestID)?.invalidate()
    }

    public func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        cancelAuthentication(requestID: requestID)
        guard let device = model.device else { throw ScreenFailure(message: MessageCopy.noKeysYet) }
        let lease = try await device.denyRemote(requestID, reply: reply ?? "")
        return Self.state(lease, members: device.members)
    }

    /// The hold after a denial is the asking computer's: nothing here lifts it.
    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        request(requestID)?.state ?? .unanswered
    }

    static func accessRequest(_ ask: MacDevice.RemoteAsk, members: Agentkeyring_V2_Members?) -> AccessRequest {
        let request = ask.request
        let state: AccessRequestState = switch ask.state {
        case .waiting: .waitingForYou(until: LeaseScreenMapping.date(request.answerByUnixSeconds))
        case let .ended(lease): Self.state(lease, members: members)
        }
        return AccessRequest(id: ask.id,
            login: RequestedLogin(site: LeaseScreenMapping.siteLabel(ask.login.sites.first ?? ask.login.title), account: ask.login.account),
            agent: RequestingAgent(name: request.agent.isEmpty ? "An agent" : request.agent, machine: ask.computer.label, address: "",
                project: request.project.isEmpty ? nil : request.project, isLocal: false),
            access: .login, agentReason: request.reason, askedAt: LeaseScreenMapping.date(request.askedUnixSeconds), state: state)
    }

    /// The request as the asking computer said it ended. Who answered is named by label in the Lease.
    static func state(_ lease: Agentkeyring_V2_Lease, members: Agentkeyring_V2_Members?) -> AccessRequestState {
        let device = members?.devices.first { $0.label == lease.answeredBy }
        let by: ApprovalSurface = device?.kind == .iphone ? .iPhone : .mac
        switch lease.state {
        case .waiting: return .waitingForYou(until: LeaseScreenMapping.date(lease.answerByUnixSeconds))
        case .approved: return .approved(by: by, until: LeaseScreenMapping.date(lease.notAfterUnixSeconds))
        case .denied:
            return .denied(by: by, reply: lease.reply.isEmpty ? nil : lease.reply,
                askAgainAfter: lease.retryNotBeforeUnixSeconds > 0 ? LeaseScreenMapping.date(lease.retryNotBeforeUnixSeconds) : nil)
        case .cancelled: return .cancelled
        case .ended: return lease.endedBy.isEmpty ? .released(at: .now) : .ended(at: .now)
        default: return .unanswered
        }
    }
}
#endif
