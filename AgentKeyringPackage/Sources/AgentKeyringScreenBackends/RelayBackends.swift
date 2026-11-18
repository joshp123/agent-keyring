// Written by AI on 2026.10.31 by model Claude Opus 5.5; rewritten on
// 2026.11.18 by the same model for protocol version 2.
//
// The Mac screens over MacDevice: requests from agents on other machines in
// the approval panel, machines and devices joining, the Machines window, and
// the remote half of the menu bar. Plumbing only.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Observation

/// Turns relay records into the values the screens show.
@MainActor
public enum RelayScreenMapping {
    public static func accessRequest(_ work: Agentkeyring_V2_Work, device: MacDevice, logins: [CredentialCandidate]) -> AccessRequest? {
        guard let request = try? Sealing.parseRequest(work.request) else { return nil }
        let login = logins.first { $0.id.uuidString == request.loginID }
        let machine = device.members?.machines.first { $0.machineID == request.machineID }
        let outcome: Agentkeyring_V2_Lease? = work.hasOutcome ? work.outcome : nil
        return AccessRequest(
            id: request.requestID,
            login: RequestedLogin(site: LeaseScreenMapping.siteLabel(login?.origins.first ?? login?.title ?? "Unknown site"),
                account: login?.username ?? login?.title ?? "Unknown account"),
            agent: RequestingAgent(name: request.agent.isEmpty ? "An agent" : request.agent,
                machine: machine?.label ?? "Another machine", address: "",
                project: request.project.isEmpty ? nil : request.project, isLocal: false),
            access: access(request),
            agentReason: request.reason,
            askedAt: date(request.askedUnixSeconds),
            state: outcome.map { state($0, device: device) } ?? .waitingForYou(until: date(request.answerByUnixSeconds)))
    }

    static func access(_ request: Agentkeyring_V2_Request) -> RequestedAccess {
        switch request.purpose {
        case .program: .program(([request.program.executable] + request.program.arguments).joined(separator: " "))
        case .agentProcess: .agentProcess
        default: .signIn
        }
    }

    static func state(_ lease: Agentkeyring_V2_Lease, device: MacDevice) -> AccessRequestState {
        let by: ApprovalSurface = device.members?.devices.first { $0.label == lease.answeredBy }?.kind == .mac ? .mac : .iPhone
        return switch lease.state {
        case .waiting: .waitingForYou(until: date(lease.answerByUnixSeconds))
        case .approved: .approved(by: by, until: date(lease.notAfterUnixSeconds))
        case .denied: .denied(by: by, reply: lease.reply.isEmpty ? nil : lease.reply,
            askAgainAfter: lease.retryNotBeforeUnixSeconds > 0 ? date(lease.retryNotBeforeUnixSeconds) : nil)
        case .cancelled: .cancelled
        case .ended: .ended(at: .now)
        default: .unanswered
        }
    }

    public static func enrolment(_ join: Agentkeyring_V2_PendingJoin) -> DeviceEnrolment {
        let (kind, name): (DeviceEnrolment.Kind, String) = switch join.request.joining {
        case let .machine(machine)?: (.machine, machine.label)
        case let .device(device)?: (.approver, device.label)
        case nil: (.machine, "")
        }
        return DeviceEnrolment(id: MacDevice.joinID(join), kind: kind, name: name, tailnetNode: join.tailscaleNodeName,
            code: "", askedAt: date(join.askedUnixSeconds))
    }

    public static func relayLink(_ device: MacDevice?) -> RelayLink {
        guard let device else { return .notSetUp }
        if let setup = device.setup { return .connecting(address: setup.endpoint.host) }
        return switch device.connection {
        case .notSetUp: .notSetUp
        case .connecting: .connecting(address: "the relay")
        case .connected: .connected(address: "the relay")
        case .unreachable: .offline(address: "the relay")
        }
    }

    static func date(_ unixSeconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }
}

/// Requests from agents on other machines, in the approval panel.
@available(macOS 26.0, *)
@MainActor
public final class RelayApprovalBackend: MacApprovalBackend {
    private let model: MirrorAppModel
    private var contexts: [String: LAContext] = [:]

    public init(model: MirrorAppModel) {
        self.model = model
    }

    public func current(_ requestID: String) -> AccessRequest? {
        guard let device = model.device, let work = device.waiting[requestID] ?? device.finished[requestID] else { return nil }
        return RelayScreenMapping.accessRequest(work, device: device, logins: model.leaseLogins)
    }

    public func updates(requestID: String) -> AsyncStream<AccessRequest> {
        streamUntilFinal(Observations { [weak self] in self?.current(requestID) })
    }

    public func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        guard let device = model.device else { throw ScreenFailure(message: "This Mac is not connected to a relay.") }
        let context = LAContext()
        contexts[requestID] = context
        defer { if contexts[requestID] === context { contexts[requestID] = nil } }
        do {
            try await screenErrors { try await device.approve(requestID, context: context, onAuthenticated: onAuthenticated) }
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
        return .approved(by: .mac, until: .now.addingTimeInterval(RequestedAccess.longestLease))
    }

    public func cancelAuthentication(requestID: String) {
        contexts.removeValue(forKey: requestID)?.invalidate()
    }

    /// A reply is signed with the Mac's reply key, which needs no Touch ID.
    public func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        guard let device = model.device else { throw ScreenFailure(message: "This Mac is not connected to a relay.") }
        try await screenErrors { try await device.deny(requestID, reply: reply ?? "") }
        return .denied(by: .mac, reply: reply, askAgainAfter: .now.addingTimeInterval(1800))
    }

    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        throw ScreenFailure(message: "A denial on another machine holds the login off for 30 minutes. It cannot be lifted from this Mac yet.")
    }
}

/// The Machines window.
@available(macOS 26.0, *)
@MainActor
public final class RelayMachinesBackend: MacMachinesBackend {
    private let model: MirrorAppModel

    public init(model: MirrorAppModel) {
        self.model = model
    }

    public func snapshot() -> MachinesSnapshot {
        let device = model.device
        let ownMachine = device?.ownMachineID
        return MachinesSnapshot(
            relay: RelayScreenMapping.relayLink(device),
            waiting: device?.joins.map(RelayScreenMapping.enrolment) ?? [],
            machines: (device?.members?.machines ?? []).filter { $0.machineID != ownMachine }.map {
                EnrolledMachine(id: $0.machineID, name: $0.label, tailnetNode: "", automaticAllowed: $0.automaticAllowed)
            },
            approvers: (device?.members?.devices ?? []).map {
                ApproverDevice(keyID: $0.keyID, name: $0.label, isPhone: $0.kind != .mac, lastTested: device?.lastTested[$0.keyID])
            })
    }

    public func updates() -> AsyncStream<MachinesSnapshot> {
        stream(Observations { [weak self] in self?.snapshot() ?? MachinesSnapshot(relay: .notSetUp) })
    }

    public func connect(host: String, port: UInt16) async throws {
        throw ScreenFailure(message: "Give an agent this task: “Set up Agent Keyring on my always-on machine.” Then approve its request here.")
    }

    public func cancelRelaySetup() throws {
        model.device?.abandonSetup()
    }

    public func removePhone(keyID: String, context: LAContext) async throws {
        try await screenErrors { try await model.device?.remove(keyID, context: context) }
    }

    public func remove(machineID: String, context: LAContext) async throws {
        try await screenErrors { try await model.device?.remove(machineID, context: context) }
    }
}

/// A failure with words a person can read, for the screens' alerts.
public struct ScreenFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Runs a relay call and turns its LeaseFailure into readable words.
@MainActor
func screenErrors(_ action: () async throws -> Void) async throws {
    do { try await action() }
    catch let failure as LeaseFailure { throw ScreenFailure(message: failure.message) }
}
#endif
