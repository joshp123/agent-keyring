// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Mac screens over the release 3 relay approver (RFC 0007 U4,
// docs/implementation/mac-relay-approver.md): remote requests in the
// approval panel, machines and iPhones joining, the Machines window, and the
// remote half of the menu bar. Plumbing only; every signature, seal and
// queue is RelayApprover's.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import Observation

/// Turns relay records into the values the screens show.
public enum RelayScreenMapping {
    /// A request waiting at the relay. `answered` is the answer Josh gave here
    /// that is still on its way, if any.
    public static func accessRequest(_ request: RelayRemoteRequest, answered: AnswerChoice?) -> AccessRequest {
        var value = LeaseScreenMapping.accessRequest(request.lease, requester: nil, login: nil)
        value = AccessRequest(
            id: request.id,
            login: RequestedLogin(site: site(request.lease, loginTitle: request.loginTitle), account: request.account),
            agent: RequestingAgent(
                name: request.record.agentLabel.isEmpty ? request.machine.clientLabel : request.record.agentLabel,
                machine: request.machine.machineLabel,
                address: request.record.tailscaleAddress,
                isLocal: false),
            access: value.access,
            agentReason: request.record.reason,
            askedAt: date(request.record.createdUnixSeconds),
            state: value.state,
            events: [],
            answerIsQueued: request.answerIsQueued)
        // Signed and saved, not yet acknowledged: show the answer Josh gave.
        if request.answerIsQueued, value.state.isWaitingForYou, let answered {
            value.state = switch answered {
            case .approve: .approved(by: .mac, until: date(request.lease.notAfterUnixSeconds > 0
                ? request.lease.notAfterUnixSeconds : request.record.pendingUntilUnixSeconds))
            case .deny: .denied(by: .mac, reply: nil, askAgainAfter: nil)
            }
        }
        return value
    }

    /// A remote lease in use or finished, as the relay last reported it.
    public static func accessRequest(_ lease: RelayRemoteLease) -> AccessRequest {
        var value = LeaseScreenMapping.accessRequest(lease.lease, requester: nil, login: nil)
        value.login = RequestedLogin(site: site(lease.lease, loginTitle: lease.loginTitle), account: lease.account)
        value.agent = RequestingAgent(name: lease.machine.clientLabel, machine: lease.machine.machineLabel,
            address: "", isLocal: false)
        value.answerIsQueued = lease.endIsQueued
        return value
    }

    public static func enrolment(_ enrolment: RelayMachineEnrolment) -> DeviceEnrolment {
        DeviceEnrolment(id: enrolment.id, kind: .machine, name: enrolment.machineLabel,
            tailnetNode: enrolment.tailscaleNodeName, code: enrolment.fingerprint, askedAt: .now)
    }

    public static func enrolment(_ pairing: RelayApproverPairing) -> DeviceEnrolment {
        DeviceEnrolment(id: pairing.id, kind: .approver, name: pairing.label, tailnetNode: "",
            code: pairing.fingerprint, askedAt: .now,
            replacesPhone: pairing.replacesPhoneKeyID == nil ? nil : pairing.replacesPhoneLabel)
    }

    public static func relayLink(_ update: RelayApproverUpdate) -> RelayLink {
        let relay = "the relay"
        if let pairing = update.pairing {
            // Confirmed but not yet acknowledged: it is connecting, not comparing.
            return pairing.answerIsQueued
                ? .connecting(address: pairing.relayAddress)
                : .comparing(code: pairing.fingerprint, address: pairing.relayAddress)
        }
        return switch update.connection {
        case .notPaired: .notSetUp
        case .connecting: .connecting(address: relay)
        case .connected: .connected(address: relay)
        case .offline, .stopped: .offline(address: relay)
        }
    }

    public static func approvers(_ update: RelayApproverUpdate) -> [ApproverDevice] {
        guard let signed = update.approverKeySet,
            let set = try? Agentkeyring_V1_ApproverKeySet(serializedBytes: signed.keySet)
        else { return [] }
        return set.keys.map { ApproverDevice(keyID: $0.keyID, name: $0.label, isPhone: $0.role == .phone) }
    }

    /// Unfinished withdrawals. A device dropped by a later change no longer
    /// has to confirm, so it is in neither list.
    public static func withdrawals(_ update: RelayApproverUpdate) -> [PendingWithdrawal] {
        update.withdrawals.filter { !$0.isComplete }.map { withdrawal in
            let counted = withdrawal.devices.filter { !$0.removedByLaterChange }
            return PendingWithdrawal(id: withdrawal.id, title: withdrawalTitle(withdrawal.label),
                confirmedOn: counted.filter(\.confirmed).map(\.label),
                waitingFor: counted.filter { !$0.confirmed }.map(\.label))
        }
    }

    /// RelayApprover names a withdrawal as a command ("Remove …"); the
    /// screen shows it as something in progress.
    static func withdrawalTitle(_ label: String) -> String {
        if label.hasPrefix("Remove ") { return "Removing " + label.dropFirst("Remove ".count) }
        if label == "Apply changed login and machine permissions" { return "Applying changed permissions" }
        return label
    }

    static func site(_ lease: Agentkeyring_V1_Lease, loginTitle: String) -> String {
        LeaseScreenMapping.siteLabel(lease.sites.first ?? loginTitle)
    }

    static func date(_ unixSeconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }
}

/// Remote requests in the approval panel.
@available(macOS 26.0, *)
@MainActor
public final class RelayApprovalBackend: MacApprovalBackend {
    private let relay: RelayApprover
    private var contexts: [String: LAContext] = [:]
    /// Answers given here, kept until the relay's report replaces them.
    public private(set) var answered: [String: AnswerChoice] = [:]

    public init(relay: RelayApprover) {
        self.relay = relay
    }

    public func current(_ requestID: String) -> AccessRequest? {
        relay.requests.first { $0.id == requestID }
            .map { RelayScreenMapping.accessRequest($0, answered: answered[requestID]) }
    }

    public func updates(requestID: String) -> AsyncStream<AccessRequest> {
        let leaseID = relay.requests.first { $0.id == requestID }?.lease.leaseID
        let relay = relay
        return streamUntilFinal(Observations { [weak self] in
            if let request = self?.current(requestID) { return request }
            return relay.leases.first { $0.lease.leaseID == leaseID }.map(RelayScreenMapping.accessRequest)
        })
    }

    public func embeddedTouchIDContext(requestID: String) -> LAContext? {
        if let context = contexts[requestID] { return context }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        contexts[requestID] = context
        return context
    }

    public func approve(requestID: String) async throws -> AccessRequestState {
        defer { contexts[requestID] = nil }
        try await screenErrors { try await relay.approve(requestID, context: contexts[requestID] ?? LAContext()) }
        answered[requestID] = .approve
        return current(requestID)?.state ?? .approved(by: .mac, until: .now.addingTimeInterval(RequestedAccess.longestLease))
    }

    public func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        contexts[requestID] = nil
        // A plain denial needs no Touch ID; a reply is signed with one.
        try await screenErrors { try await relay.deny(requestID, reply: reply ?? "") }
        answered[requestID] = .deny
        return .denied(by: .mac, reply: reply, askAgainAfter: nil)
    }
}

/// Machines and iPhones joining, in the enrolment panel.
@available(macOS 26.0, *)
@MainActor
public final class RelayEnrolmentBackend: MacEnrolmentBackend {
    private let relay: RelayApprover

    public init(relay: RelayApprover) {
        self.relay = relay
    }

    public func current(_ enrolmentID: String) -> DeviceEnrolment? {
        relay.pendingEnrolments.first { $0.id == enrolmentID }.map(RelayScreenMapping.enrolment)
            ?? relay.pendingApproverPairings.first { $0.id == enrolmentID }.map(RelayScreenMapping.enrolment)
    }

    public func updates(enrolmentID: String) -> AsyncStream<DeviceEnrolment?> {
        stream(Observations { [weak self] in self?.current(enrolmentID) })
    }

    public func approve(enrolmentID: String, comparedCode: String, allowAutomatic: Bool) async throws {
        if relay.pendingApproverPairings.contains(where: { $0.id == enrolmentID }) {
            try await screenErrors {
                try await relay.confirmApproverPairing(enrolmentID, comparedFingerprint: comparedCode, context: LAContext())
            }
        } else {
            try await screenErrors {
                try await relay.approveEnrolment(enrolmentID, comparedFingerprint: comparedCode,
                    automaticAllowed: allowAutomatic, context: LAContext())
            }
        }
    }

    public func refuse(enrolmentID: String) async throws {
        if relay.pendingApproverPairings.contains(where: { $0.id == enrolmentID }) {
            // Local and durable: no relay call, no Touch ID.
            try screenErrors { try relay.dismissApproverPairing(enrolmentID) }
            return
        }
        try await screenErrors { try await relay.denyEnrolment(enrolmentID, context: LAContext()) }
    }
}

/// The Machines window.
@available(macOS 26.0, *)
@MainActor
public final class RelayMachinesBackend: MacMachinesBackend {
    private let relay: RelayApprover
    private let routing: ApprovalRoutingSettings

    public init(relay: RelayApprover, routing: ApprovalRoutingSettings) {
        self.relay = relay
        self.routing = routing
    }

    public func snapshot() -> MachinesSnapshot {
        let update = relay.update
        return MachinesSnapshot(
            relay: RelayScreenMapping.relayLink(update),
            queuedAnswers: update.queuedAnswerCount,
            isApplying: update.isApplying,
            waiting: update.enrolments.map(RelayScreenMapping.enrolment)
                + update.approverPairings.map(RelayScreenMapping.enrolment),
            machines: update.machines.map {
                EnrolledMachine(id: $0.recipientID, name: $0.machineLabel, tailnetNode: $0.clientLabel,
                    automaticAllowed: $0.automaticAllowed)
            },
            approvers: RelayScreenMapping.approvers(update),
            withdrawals: RelayScreenMapping.withdrawals(update),
            askPhoneAfter: .seconds(routing.phoneDelaySeconds))
    }

    public func updates() -> AsyncStream<MachinesSnapshot> {
        stream(Observations { [weak self] in self?.snapshot() ?? MachinesSnapshot(relay: .notSetUp) })
    }

    public func connect(host: String, port: UInt16) async throws {
        try await screenErrors { try await relay.beginPairing(try RelayEndpoint(host: host, port: port)) }
    }

    public func confirmRelay(comparedCode: String) async throws {
        try await screenErrors { try await relay.confirmPairing(comparedFingerprint: comparedCode, context: LAContext()) }
    }

    public func cancelRelaySetup() throws {
        try screenErrors { try relay.abandonPairing() }
    }

    public func removePhone(keyID: String) async throws {
        try await screenErrors { try await relay.removePhone(keyID, context: LAContext()) }
    }

    public func remove(machineID: String) async throws {
        try await screenErrors { try await relay.revokeMachine(machineID, context: LAContext()) }
    }

    /// The Mac's escalation delay (RFC 0006), stored on this Mac.
    public func setAskPhoneAfter(_ delay: Duration) {
        routing.phoneDelaySeconds = Int(delay.components.seconds)
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

@MainActor
func screenErrors(_ action: () throws -> Void) throws {
    do { try action() }
    catch let failure as LeaseFailure { throw ScreenFailure(message: failure.message) }
}
#endif
