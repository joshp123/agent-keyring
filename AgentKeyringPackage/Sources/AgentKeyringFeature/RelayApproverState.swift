import AgentKeyringRelaySupport
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

public struct RelayRemoteLease: Identifiable, Sendable {
    public var id: String { lease.leaseID }
    public let lease: Agentkeyring_V1_Lease
    public let loginTitle: String
    public let account: String
    public let machine: Agentkeyring_V1_EnrolledMachine
    public let endIsQueued: Bool
}

public struct RelayApproverUpdate: Sendable {
    public let connection: RelayApproverConnectionState
    public let pairing: RelayPairingComparison?
    public let enrolments: [RelayMachineEnrolment]
    public let approverPairings: [RelayApproverPairing]
    public let approverKeySet: Agentkeyring_V1_SignedApproverKeySet?
    public let requests: [RelayRemoteRequest]
    public let leases: [RelayRemoteLease]
    public let machines: [Agentkeyring_V1_EnrolledMachine]
    public let queuedAnswerCount: Int
    public let needsPublication: Bool
    public let isApplying: Bool
    public let withdrawals: [RelayPermissionWithdrawal]
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
    var phoneDue: Int64?
    var escalated: Bool?
}
struct RelayQueuedCommand: Codable {
    var id: String
    var bytes: Data
    var attempted: Bool?
}
struct RelaySavedLeaseReport: Codable {
    var lease: Data
    var title: String
    var account: String
    var machine: Data
}
struct RelayPendingPair: Codable {
    var endpoint: RelayEndpoint
    var relaySPKI: Data
    var transcript: Data
    var confirmation: Data?
    var automaticKeys: Data?
}
struct RelaySavedCopy: Codable {
    var revision: UInt64
    var configurationRevision: UInt64
    var generationID: UUID
}
struct RelayApproverState: Codable {
    var version = 1
    var endpoint: RelayEndpoint?
    var relaySPKI: Data?
    var pairing: RelayPendingPair?
    var keySet: Data?
    var machines: [String: Data] = [:]
    var pendingEnrolments: [String: Data] = [:]
    var pendingApprovers: [String: Data]?
    var pendingApproverCreated: [String: Int64]?
    var dismissedApproverPairingIDs: Set<String>?
    var requests: [String: RelaySavedRequest] = [:]
    var leaseReports: [String: RelaySavedLeaseReport]?
    var outbox: [RelayQueuedCommand] = []
    var configuration: Data?
    var acknowledgedConfigurationRevision: UInt64?
    var automaticKeys: Data?
    var loginCopies: [String: RelaySavedCopy]?
    var suppressions: [String: Int64] = [:]
    var withdrawals: [String: RelaySavedWithdrawal]?
    var withdrawalSequence: UInt64?
    var acknowledgedUpdateReceipts: Set<String>?
}

@MainActor @Observable
public final class RelayApprover {
    public internal(set) var connectionState = RelayApproverConnectionState.notPaired
    public private(set) var pairing: RelayPairingComparison?
    public private(set) var pendingEnrolments: [RelayMachineEnrolment] = []
    public private(set) var pendingApproverPairings: [RelayApproverPairing] = []
    public private(set) var approverKeySet: Agentkeyring_V1_SignedApproverKeySet?
    public private(set) var requests: [RelayRemoteRequest] = []
    public private(set) var leases: [RelayRemoteLease] = []
    public private(set) var enrolledMachines: [Agentkeyring_V1_EnrolledMachine] = []
    public private(set) var queuedAnswerCount = 0
    public internal(set) var needsPublication = false
    public private(set) var isApplying = false
    public private(set) var withdrawals: [RelayPermissionWithdrawal] = []
    public internal(set) var errorMessage: String?

    let legacyPersistence: LeasePersistence?
    let leaseStore: CredentialLeaseStore
    let credentialSource: @MainActor () async throws -> RelayApproverVault
    let suppliedIdentity: RelayTLSIdentity?
    let suppliedSigner: (any RelayApproverSigning)?
    let lockState: any CredentialSessionLockState
    var identity: RelayTLSIdentity?
    var signer: (any RelayApproverSigning)?
    var state: RelayApproverState { leaseStore.relayState }
    var loaded = false
    var workTask: Task<Void, Never>?
    var outboxTask: Task<Void, Never>?
    let phoneDelay: @MainActor () -> Int
    var pairConnection: RelayConnection?
    var pairingAttemptID = UUID()
    var sessionTask: Task<Void, Never>?
    var isFlushing = false
    var authorizationID: String?
    var rulesCheckGeneration = 0
    var rulesAreBeingChecked = false
    var rulesDifferFromConfiguration = false
    var publicationConfirmationChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var observers: [UUID: AsyncStream<RelayApproverUpdate>.Continuation] = [:]

    public init(persistence: LeasePersistence? = nil,
        leaseStore: CredentialLeaseStore = CredentialLeaseStore(),
        phoneDelay: @escaping @MainActor () -> Int = { 120 },
        identity: RelayTLSIdentity? = nil, signer: (any RelayApproverSigning)? = nil,
        lockState: any CredentialSessionLockState = SystemCredentialSessionLockState(),
        credentialSource: @escaping @MainActor () async throws -> RelayApproverVault) {
        self.legacyPersistence = persistence ?? leaseStore.relayMigrationPersistence
        self.leaseStore = leaseStore
        self.phoneDelay = phoneDelay
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
        try leaseStore.load()
        if !leaseStore.hasRelayState, let bytes = try legacyPersistence?.load() {
            var migrated = try PropertyListDecoder().decode(RelayApproverState.self, from: bytes)
            guard migrated.version == 1 else { throw LeaseFailure(.unavailable, "This relay state needs a newer Agent Keyring.") }
            migrated.outbox = try migrated.outbox.filter {
                try Agentkeyring_V1_RelayWireRequest(serializedBytes: $0.bytes).request != nil
            }
            try leaseStore.saveRelayState(migrated)
        }
        leaseStore.onCommit = { [weak self] in
            self?.publish()
            self?.wakeOutbox()
        }
        loaded = true
        try queueCollectedUpdateAcknowledgements()
        publish()
    }

    func keys() throws -> (RelayTLSIdentity, any RelayApproverSigning) {
        if identity == nil { identity = try suppliedIdentity ?? RelayTLSIdentity.loadMacIdentity() }
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
            requests: requests, leases: leases, machines: enrolledMachines, queuedAnswerCount: queuedAnswerCount,
            needsPublication: needsPublication, isApplying: isApplying, withdrawals: withdrawals, errorMessage: errorMessage)
    }

    func commit(_ next: RelayApproverState, vault: RelayApproverVault? = nil, rules: CredentialLeaseStore.SavedRules? = nil) throws {
        try leaseStore.saveRelayState(next, vault: vault, rules: rules)
        if vault != nil { rulesDifferFromConfiguration = false }
        publish()
        wakeOutbox()
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
                let pin = state.relaySPKI, let current = approverKeySet,
                let keySet = try? Agentkeyring_V1_ApproverKeySet(serializedBytes: current.keySet) else { return nil }
            let replaced = phoneBeingReplaced(by: request, in: keySet)
            return RelayApproverPairing(id: id, label: request.key.label,
                fingerprint: RelayCrypto.fingerprint(RelayCrypto.pairTranscript(relaySPKI: pin,
                    approverSPKI: request.tlsPublicKey, signingKey: request.key.publicKey, keySet: current.keySet,
                    encryptionKey: request.key.encryptionPublicKey)),
                answerIsQueued: state.outbox.contains { $0.id == "approver-pairing:" + id },
                replacesPhoneKeyID: replaced?.keyID, replacesPhoneLabel: replaced?.label)
        }.sorted { $0.id < $1.id }
        requests = state.requests.compactMap { digest, saved in
            guard let record = try? Agentkeyring_V1_RequestRecord(serializedBytes: saved.record),
                let lease = try? Agentkeyring_V1_Lease(serializedBytes: saved.lease),
                let machine = try? Agentkeyring_V1_EnrolledMachine(serializedBytes: saved.machine) else { return nil }
            return RelayRemoteRequest(id: digest, record: record, lease: lease, loginTitle: saved.title,
                account: saved.account, machine: machine, answerIsQueued: state.outbox.contains { $0.id == "decision:" + digest })
        }.sorted { $0.lease.requestedAtUnixSeconds > $1.lease.requestedAtUnixSeconds }
        var displayedLeases = Dictionary(uniqueKeysWithValues: requests.map { request in (request.lease.leaseID,
            RelayRemoteLease(lease: request.lease, loginTitle: request.loginTitle, account: request.account, machine: request.machine,
                endIsQueued: state.outbox.contains { $0.id == "revoke-lease:" + request.lease.leaseID })) })
        for (id, saved) in state.leaseReports ?? [:] {
            guard let lease = try? Agentkeyring_V1_Lease(serializedBytes: saved.lease),
                let machine = try? Agentkeyring_V1_EnrolledMachine(serializedBytes: saved.machine) else { continue }
            if let local = displayedLeases[id], Self.isTerminal(local.lease.state), local.lease.state != .cancelled { continue }
            displayedLeases[id] = RelayRemoteLease(lease: lease, loginTitle: saved.title, account: saved.account,
                machine: machine, endIsQueued: state.outbox.contains { $0.id == "revoke-lease:" + id })
        }
        leases = displayedLeases.values.sorted { $0.lease.requestedAtUnixSeconds > $1.lease.requestedAtUnixSeconds }
        queuedAnswerCount = state.outbox.filter { !Self.isPublication($0) }.count
        withdrawals = displayedWithdrawals
        isApplying = state.outbox.contains(where: Self.isPublication) || state.hasPendingWithdrawals
        needsPublication = state.keySet != nil && (state.configuration == nil || rulesDifferFromConfiguration)
        publicationConfirmationChanged?(needsPublication)
        for observer in observers.values { observer.yield(update) }
    }

    static func isPublication(_ command: RelayQueuedCommand) -> Bool {
        command.id.hasPrefix("configuration:") || command.id.hasPrefix("login-copy:")
            || command.id.hasPrefix("remove-phone:") || command.id.hasPrefix("approver-pairing:")
            || command.id.hasPrefix("update-receipt:")
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
