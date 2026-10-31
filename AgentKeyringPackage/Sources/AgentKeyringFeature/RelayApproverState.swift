import AgentKeyringProtocol
import Foundation
import Observation

public struct RelayApproverVault: Sendable {
    let generation: MirrorGeneration
    let policies: [UUID: CredentialAccessPolicy]
    public init(generation: MirrorGeneration, policies: [UUID: CredentialAccessPolicy]) {
        self.generation = generation
        self.policies = policies
    }
}

public enum RelayApproverConnectionState: Equatable, Sendable {
    case notPaired, connecting, connected, offline, stopped
}

public struct RelayPairingComparison: Equatable, Sendable {
    public let fingerprint: String
    public let relayAddress: String
    public let answerIsQueued: Bool
}

public struct RelayMachineEnrolment: Identifiable, Sendable {
    public let id: String
    public let machineLabel: String
    public let clientLabel: String
    public let tailscaleNodeName: String
    public let fingerprint: String
}

public struct RelayRemoteRequest: Identifiable, Sendable {
    public let id: String
    public let record: Agentkeyring_V1_RequestRecord
    public let lease: Agentkeyring_V1_Lease
    public let loginTitle: String
    public let account: String
    public let machine: Agentkeyring_V1_EnrolledMachine
    public let answerIsQueued: Bool
}

public struct RelayApproverUpdate: Sendable {
    public let connection: RelayApproverConnectionState
    public let pairing: RelayPairingComparison?
    public let enrolments: [RelayMachineEnrolment]
    public let approverPairings: [RelayApproverPairing]
    public let approverKeySet: Agentkeyring_V1_SignedApproverKeySet?
    public let requests: [RelayRemoteRequest]
    public let machines: [Agentkeyring_V1_EnrolledMachine]
    public let queuedAnswerCount: Int
    public let needsPublication: Bool
    public let errorMessage: String?
}

struct RelaySavedRequest: Codable {
    var record: Data
    var lease: Data
    var title: String
    var account: String
    var machine: Data
    var decision: Data?
    var acknowledged = false
}
struct RelayQueuedCommand: Codable {
    var id: String
    var bytes: Data
}
struct RelayPendingPair: Codable {
    var endpoint: RelayEndpoint
    var relaySPKI: Data
    var transcript: Data
    var confirmation: Data?
}
struct RelayApproverState: Codable {
    var version = 1
    var endpoint: RelayEndpoint?
    var relaySPKI: Data?
    var pairing: RelayPendingPair?
    var keySet: Data?
    var machines: [String: Data] = [:]
    var approvedEnrolments: [String: Data] = [:]
    var pendingEnrolments: [String: Data] = [:]
    var pendingApprovers: [String: Data]?
    var requests: [String: RelaySavedRequest] = [:]
    var outbox: [RelayQueuedCommand] = []
    var index: Data?
    var automaticGrant: Data?
    var enrolmentSet: Data?
    var indexRevision: UInt64 = 0
    var grantRevision: UInt64 = 0
    var rosterRevision: UInt64 = 0
    var publicationDigest: Data?
    var suppressions: [String: Int64] = [:]
}

@MainActor @Observable
public final class RelayApprover {
    public internal(set) var connectionState = RelayApproverConnectionState.notPaired
    public private(set) var pairing: RelayPairingComparison?
    public private(set) var pendingEnrolments: [RelayMachineEnrolment] = []
    public private(set) var pendingApproverPairings: [RelayApproverPairing] = []
    public private(set) var approverKeySet: Agentkeyring_V1_SignedApproverKeySet?
    public private(set) var requests: [RelayRemoteRequest] = []
    public private(set) var enrolledMachines: [Agentkeyring_V1_EnrolledMachine] = []
    public private(set) var queuedAnswerCount = 0
    public internal(set) var needsPublication = false
    public internal(set) var errorMessage: String?

    let persistence: LeasePersistence
    let credentialSource: @MainActor () async throws -> RelayApproverVault
    let suppliedIdentity: RelayTLSIdentity?
    let suppliedSigner: (any RelayApproverSigning)?
    let lockState: any CredentialSessionLockState
    var identity: RelayTLSIdentity?
    var signer: (any RelayApproverSigning)?
    var state = RelayApproverState()
    var loaded = false
    var workTask: Task<Void, Never>?
    var outboxTask: Task<Void, Never>?
    var pairConnection: RelayConnection?
    var sessionTask: Task<Void, Never>?
    var isFlushing = false
    var authorizationID: String?
    var rulesCheckGeneration = 0
    var rulesAreBeingChecked = false
    @ObservationIgnored var observers: [UUID: AsyncStream<RelayApproverUpdate>.Continuation] = [:]

    public init(persistence: LeasePersistence = LeasePersistence(directory: RelayApprover.defaultDirectory(),
        checkpointService: "com.agentkeyring.relay-approver-checkpoint.v1"),
        identity: RelayTLSIdentity? = nil, signer: (any RelayApproverSigning)? = nil,
        lockState: any CredentialSessionLockState = SystemCredentialSessionLockState(),
        credentialSource: @escaping @MainActor () async throws -> RelayApproverVault) {
        self.persistence = persistence
        self.suppliedIdentity = identity
        self.suppliedSigner = signer
        self.lockState = lockState
        self.credentialSource = credentialSource
    }

    public static func defaultDirectory() -> URL {
        CredentialAccessPolicyStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("relay-approver")
    }

    public func load() throws {
        guard !loaded else { return }
        if let bytes = try persistence.load() {
            state = try PropertyListDecoder().decode(RelayApproverState.self, from: bytes)
            guard state.version == 1 else { throw LeaseFailure(.unavailable, "This relay state needs a newer Agent Keyring.") }
        }
        loaded = true
        publish()
    }

    func keys() throws -> (RelayTLSIdentity, any RelayApproverSigning) {
        if identity == nil { identity = try suppliedIdentity ?? RelayTLSIdentity.loadOrCreate() }
        if signer == nil { signer = try suppliedSigner ?? SecureEnclaveRelaySigner() }
        return (identity!, signer!)
    }

    func transport() throws -> RelayTransport {
        guard let endpoint = state.endpoint, let pin = state.relaySPKI, state.keySet != nil else {
            throw LeaseFailure(.permissionDenied, "Pair this Mac with the relay first.")
        }
        return RelayTransport(endpoint: endpoint, identity: try keys().0, pin: pin)
    }

    public func changes() -> AsyncStream<RelayApproverUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RelayApproverUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(update)
        continuation.onTermination = { @Sendable [weak self] _ in Task { @MainActor in self?.observers.removeValue(forKey: id) } }
        return stream
    }

    public var update: RelayApproverUpdate {
        RelayApproverUpdate(connection: connectionState, pairing: pairing, enrolments: pendingEnrolments,
            approverPairings: pendingApproverPairings, approverKeySet: approverKeySet,
            requests: requests, machines: enrolledMachines, queuedAnswerCount: queuedAnswerCount,
            needsPublication: needsPublication, errorMessage: errorMessage)
    }

    func commit(_ next: RelayApproverState) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try persistence.save(encoder.encode(next))
        state = next
        publish()
    }

    func publish() {
        pairing = state.pairing.map { RelayPairingComparison(fingerprint: RelayCrypto.fingerprint($0.transcript),
            relayAddress: "\($0.endpoint.host):\($0.endpoint.port)", answerIsQueued: $0.confirmation != nil) }
        enrolledMachines = state.machines.values.compactMap { try? Agentkeyring_V1_EnrolledMachine(serializedBytes: $0) }
            .sorted { $0.machineLabel < $1.machineLabel }
        pendingEnrolments = state.pendingEnrolments.compactMap { digest, bytes in
            guard let record = try? Agentkeyring_V1_EnrolmentRecord(serializedBytes: bytes),
                let pin = state.relaySPKI, let keySet = try? currentKeySet() else { return nil }
            return RelayMachineEnrolment(id: digest, machineLabel: record.machineLabel, clientLabel: record.clientLabel,
                tailscaleNodeName: record.tailscaleNodeName,
                fingerprint: RelayCrypto.fingerprint(RelayCrypto.enrolTranscript(relaySPKI: pin,
                    clientSPKI: record.tlsPublicKey, receiverKey: record.receiverPublicKey, keySet: keySet.keySet)))
        }.sorted { $0.id < $1.id }
        approverKeySet = try? currentKeySet()
        pendingApproverPairings = (state.pendingApprovers ?? [:]).compactMap { id, bytes in
            guard let request = try? Agentkeyring_V1_PairApproverRequest(serializedBytes: bytes),
                let pin = state.relaySPKI, let current = approverKeySet else { return nil }
            return RelayApproverPairing(id: id, label: request.key.label,
                fingerprint: RelayCrypto.fingerprint(RelayCrypto.pairTranscript(relaySPKI: pin,
                    approverSPKI: request.tlsPublicKey, signingKey: request.key.publicKey, keySet: current.keySet)),
                answerIsQueued: state.outbox.contains { $0.id == "approver-pairing:" + id })
        }.sorted { $0.id < $1.id }
        requests = state.requests.compactMap { digest, saved in
            guard let record = try? Agentkeyring_V1_RequestRecord(serializedBytes: saved.record),
                let lease = try? Agentkeyring_V1_Lease(serializedBytes: saved.lease),
                let machine = try? Agentkeyring_V1_EnrolledMachine(serializedBytes: saved.machine) else { return nil }
            return RelayRemoteRequest(id: digest, record: record, lease: lease, loginTitle: saved.title,
                account: saved.account, machine: machine, answerIsQueued: state.outbox.contains { $0.id == "decision:" + digest })
        }.sorted { $0.lease.requestedAtUnixSeconds > $1.lease.requestedAtUnixSeconds }
        queuedAnswerCount = state.outbox.count
        for observer in observers.values { observer.yield(update) }
    }

    func currentKeySet() throws -> Agentkeyring_V1_SignedApproverKeySet {
        guard let bytes = state.keySet else { throw LeaseFailure(.permissionDenied, "This Mac is not paired.") }
        return try Agentkeyring_V1_SignedApproverKeySet(serializedBytes: bytes)
    }
    func enqueue(_ command: Agentkeyring_V1_RelayWireRequest, id: String, into next: inout RelayApproverState) throws {
        let bytes = try command.serializedData()
        if let existing = next.outbox.first(where: { $0.id == id }) {
            guard existing.bytes == bytes else { throw LeaseFailure(.conflict, "A different answer is already waiting for delivery.") }
        } else { next.outbox.append(RelayQueuedCommand(id: id, bytes: bytes)) }
    }
    static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    func claimAuthorization(_ id: String) throws {
        guard authorizationID == nil else { throw LeaseFailure(.conflict, "Another approval is already in progress on this Mac.") }
        authorizationID = id
    }
}
