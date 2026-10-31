import AgentKeyringProtocol
import Foundation
import Observation

public struct LeaseFailure: Error, Sendable {
    public let code: Agentkeyring_V1_RpcErrorCode
    public let message: String
    public init(_ code: Agentkeyring_V1_RpcErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct CredentialLeaseRequester: Codable, Sendable {
    public let name: String
    public let workingDirectory: String?
    public let machineName: String
    public let networkAddress: String?

    init(_ requester: AgentRequester) {
        name = requester.name
        workingDirectory = requester.workingDirectory
        machineName = requester.machineName
        networkAddress = requester.networkAddress
    }
}

/// Authority methods run synchronously on the main actor: the durable commit
/// precedes publication and value delivery, with no suspension between them.
@MainActor @Observable
public final class CredentialLeaseStore {
    private struct RequestRecord: Codable {
        var request: Data
        var leaseID: String
    }
    private struct SavedOperation: Codable {
        var request: Data
        var record: Data
    }
    private struct SavedLease: Codable {
        var lease: Data
        var automatic: Bool
        var requester: CredentialLeaseRequester? = nil
        var operations: [String: SavedOperation] = [:]
    }
    private struct Suppression: Codable {
        var until: Int64
        var reply: String
    }
    private struct Snapshot: Codable {
        var version = 1
        var recipient: Data
        var leases: [String: SavedLease] = [:]
        var requests: [String: RequestRecord] = [:]
        var suppressions: [String: Suppression] = [:]
    }
    private var snapshot: Snapshot?
    private let persistence: LeasePersistence
    public private(set) var leases: [Agentkeyring_V1_Lease] = []
    public private(set) var errorMessage: String?
    public private(set) var needsHistoryReset = false
    @ObservationIgnored private var observers: [UUID: AsyncStream<[Agentkeyring_V1_Lease]>.Continuation] = [:]

    public init(persistence: LeasePersistence = LeasePersistence()) { self.persistence = persistence }
    public var waitingRequests: [Agentkeyring_V1_Lease] { leases.filter { $0.state == .pending } }
    public var activeLeases: [Agentkeyring_V1_Lease] { leases.filter { $0.state == .active } }

    public func load() throws {
        guard snapshot == nil else { return }
        do {
            if let bytes = try persistence.load() {
                let saved = try PropertyListDecoder().decode(Snapshot.self, from: bytes)
                guard saved.version == 1 else { throw LeaseFailure(.unavailable, "This lease state needs a newer Agent Keyring.") }
                snapshot = saved
            } else {
                try commit(emptySnapshot())
            }
            try expire()
            errorMessage = nil
            needsHistoryReset = false
            publish()
        } catch {
            snapshot = nil
            needsHistoryReset = true
            errorMessage = "Task history could not be opened. Task access on this Mac is stopped. Open Agent Keyring and choose Reset task history."
            publish()
            throw LeaseFailure(.unavailable, errorMessage!)
        }
    }

    /// Called only after the owner approves resetting the unavailable history.
    /// A new recipient and empty records make every old reference unusable.
    func resetHistoryAfterOwnerConfirmation() throws {
        guard needsHistoryReset else { return }
        try commit(emptySnapshot())
        errorMessage = nil
        needsHistoryReset = false
    }

    private func emptySnapshot() throws -> Snapshot {
        var recipient = Agentkeyring_V1_Recipient()
        recipient.recipientID = UUID().uuidString
        recipient.machineLabel = Host.current().localizedName ?? "This Mac"
        recipient.clientLabel = "Local agents"
        return Snapshot(recipient: try recipient.serializedData())
    }

    public func changes() -> AsyncStream<[Agentkeyring_V1_Lease]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Agentkeyring_V1_Lease]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(leases)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.observers.removeValue(forKey: id) }
        }
        return stream
    }

    public func recipient() throws -> Agentkeyring_V1_Recipient {
        try load()
        return try Agentkeyring_V1_Recipient(serializedBytes: snapshot!.recipient)
    }

    /// The bridge has authenticated the local OS peer. Release 2 deliberately
    /// has one principal/recipient for that OS user, independent of process IDs.
    public func request(_ incoming: Agentkeyring_V1_RequestLeaseRequest, login: CredentialCandidate?,
        policy: CredentialAccessPolicy, requester: CredentialLeaseRequester? = nil) throws -> Agentkeyring_V1_Lease {
        try load()
        var request = incoming
        guard let loginID = UUID(uuidString: request.loginID), !request.requestID.isEmpty,
            !request.taskRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            [.browserSignIn, .program, .agentProcess].contains(request.purpose),
            request.hasProgram == (request.purpose == .program) else {
            throw LeaseFailure(.invalidArgument, "Supply a login, unique request ID, task, reason and delivery purpose; only program leases include a command.")
        }
        if request.hasProgram {
            guard request.program.executable.hasPrefix("/"), !request.program.executable.utf8.contains(0),
                !request.program.arguments.contains(where: { $0.utf8.contains(0) }) else {
                throw LeaseFailure(.invalidArgument, "Program leases require a resolved absolute executable and valid arguments.")
            }
        }
        request.loginID = loginID.uuidString
        let localRecipient = try recipient()
        guard request.recipientID.isEmpty || request.recipientID == localRecipient.recipientID else {
            throw LeaseFailure(.permissionDenied, "That recipient is not available to this local caller.")
        }
        request.recipientID = localRecipient.recipientID
        if let existing = snapshot!.requests[request.requestID] {
            guard try Agentkeyring_V1_RequestLeaseRequest(serializedBytes: existing.request) == request else {
                throw LeaseFailure(.conflict, "This request ID was already used with different contents.")
            }
            return try get(existing.leaseID)
        }
        try expire()
        guard let login, login.id == loginID else { throw LeaseFailure(.notFound, "The selected login is no longer available.") }
        var next = snapshot!
        if let joined = leases.first(where: {
            ($0.state == .pending || $0.state == .active) && $0.loginID == request.loginID
                && $0.taskRef == request.taskRef && $0.purpose == request.purpose
                && $0.recipient.recipientID == request.recipientID
        }) {
            guard joined.hasProgram == request.hasProgram, joined.program == request.program else {
                throw LeaseFailure(.conflict, "The current lease for this task has a different program. End it before requesting another command.")
            }
            next.requests[request.requestID] = RequestRecord(request: try request.serializedData(), leaseID: joined.leaseID)
            try commit(next)
            return joined
        }
        let now = Self.now
        var lease = Agentkeyring_V1_Lease()
        lease.leaseID = UUID().uuidString
        lease.loginID = request.loginID
        lease.taskRef = request.taskRef
        lease.purpose = request.purpose
        lease.reason = request.reason
        lease.requestedAtUnixSeconds = now
        lease.recipient = localRecipient
        lease.sites = login.origins
        if request.hasProgram { lease.program = request.program }
        lease.pendingUntilUnixSeconds = now + 600
        if policy == .block {
            lease.state = .denied
            lease.endedAtUnixSeconds = now
            lease.statusLines = ["This login is blocked in Agent Keyring."]
        } else if let suppression = next.suppressions[request.loginID], suppression.until > now {
            lease.state = .denied
            lease.endedAtUnixSeconds = now
            lease.retryNotBeforeUnixSeconds = suppression.until
            lease.reply = suppression.reply
            lease.statusLines = ["A recent denial is still in effect. Wait for Josh to clear it or start a new request later."]
        } else if policy == .allowAutomatically {
            lease.state = .active
            lease.approvedBy = .automaticRule
            lease.approvedAtUnixSeconds = now
            lease.notAfterUnixSeconds = now + 1800
        } else {
            lease.state = .pending
            lease.statusLines = ["Waiting for approval in Agent Keyring."]
        }
        next.leases[lease.leaseID] = SavedLease(lease: try lease.serializedData(), automatic: policy == .allowAutomatically, requester: requester)
        next.requests[request.requestID] = RequestRecord(request: try request.serializedData(), leaseID: lease.leaseID)
        try commit(next)
        return lease
    }

    public func requester(for leaseID: String) -> CredentialLeaseRequester? { snapshot?.leases[leaseID]?.requester }

    public func get(_ leaseID: String) throws -> Agentkeyring_V1_Lease {
        try load()
        try expire()
        guard let saved = snapshot!.leases[leaseID] else { throw LeaseFailure(.notFound, "No such lease.") }
        return try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
    }

    /// Call only after successful Touch ID. Late/duplicate answers cannot revive a lease.
    func approve(_ leaseID: String) throws -> Agentkeyring_V1_Lease {
        var lease = try get(leaseID)
        guard lease.state == .pending else { return lease }
        lease.state = .active
        lease.approvedBy = .mac
        let approvedAt = Self.now
        lease.approvedAtUnixSeconds = approvedAt
        lease.notAfterUnixSeconds = approvedAt + 1800
        lease.statusLines = []
        try saveLease(lease)
        return lease
    }

    public func deny(_ leaseID: String, reply: String = "") throws -> Agentkeyring_V1_Lease {
        var lease = try get(leaseID)
        guard lease.state == .pending else { return lease }
        lease.state = .denied
        lease.reply = reply
        lease.endedAtUnixSeconds = Self.now
        lease.retryNotBeforeUnixSeconds = lease.endedAtUnixSeconds + 1800
        lease.statusLines = ["The request was denied."]
        var next = snapshot!
        next.suppressions[lease.loginID] = Suppression(until: lease.retryNotBeforeUnixSeconds, reply: reply)
        next.leases[leaseID]!.lease = try lease.serializedData()
        // One denial covers this recipient/login, including already waiting tasks.
        for (id, saved) in next.leases where id != leaseID {
            var waiting = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if waiting.loginID == lease.loginID, waiting.state == .pending {
                waiting.state = .denied
                waiting.endedAtUnixSeconds = lease.endedAtUnixSeconds
                waiting.reply = reply
                waiting.retryNotBeforeUnixSeconds = lease.retryNotBeforeUnixSeconds
                next.leases[id]!.lease = try waiting.serializedData()
            }
        }
        try commit(next)
        return lease
    }

    public func clearDenial(loginID: String) throws {
        try load()
        var next = snapshot!
        let normalizedID = UUID(uuidString: loginID)?.uuidString ?? loginID
        next.suppressions.removeValue(forKey: normalizedID)
        for (id, saved) in next.leases {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.loginID == normalizedID, lease.state == .denied, lease.retryNotBeforeUnixSeconds != 0 {
                lease.retryNotBeforeUnixSeconds = 0
                next.leases[id]!.lease = try lease.serializedData()
            }
        }
        try commit(next)
    }

    @discardableResult public func end(_ leaseID: String) throws -> Agentkeyring_V1_Lease {
        var lease = try get(leaseID)
        if lease.state == .pending { lease.state = .cancelled }
        else if lease.state == .active { lease.state = .released }
        else { return lease }
        lease.endedAtUnixSeconds = Self.now
        try saveLease(lease)
        return lease
    }

    /// Josh ended access. This is distinct from the agent finishing its task.
    @discardableResult public func revoke(_ leaseID: String) throws -> Agentkeyring_V1_Lease {
        var lease = try get(leaseID)
        guard !lease.state.isTerminal else { return lease }
        lease.state = .revoked
        lease.endedAtUnixSeconds = Self.now
        lease.statusLines = ["You ended access to this login."]
        try saveLease(lease)
        return lease
    }

    /// A new import may narrow destinations, never broaden an existing lease.
    public func reconcile(logins: [CredentialCandidate], policies: [UUID: CredentialAccessPolicy], rulesConfirmed: Bool) throws {
        try load()
        try expire()
        var next = snapshot!
        for (id, saved) in next.leases {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            guard lease.state == .pending || lease.state == .active else { continue }
            let login = logins.first { $0.id.uuidString == lease.loginID }
            let rule = login.map { policies[$0.id, default: .ask] }
            if !rulesConfirmed || login == nil || rule == .block || (saved.automatic && rule != .allowAutomatically) {
                lease.state = .revoked
                lease.statusLines = ["Access to this login changed. The lease was ended."]
            } else if let login {
                lease.sites = lease.sites.filter { login.origins.contains($0) }
                if lease.sites.isEmpty { lease.state = .revoked }
            }
            if lease.state.isTerminal { lease.endedAtUnixSeconds = Self.now }
            next.leases[id]!.lease = try lease.serializedData()
        }
        if next.leases.mapValues(\.lease) != snapshot!.leases.mapValues(\.lease) { try commit(next) }
    }

    public func begin(_ request: Agentkeyring_V1_BeginOperationRequest,
        values: (Agentkeyring_V1_Lease, [Agentkeyring_V1_CredentialField]) throws -> Agentkeyring_V1_CredentialValues
    ) throws -> Agentkeyring_V1_BeginOperationResponse {
        let lease = try get(request.leaseID)
        guard request.operationDigest.count == 32, !request.fields.isEmpty,
            Set(request.fields.map(\.rawValue)).count == request.fields.count,
            request.fields.allSatisfy({ [.username, .password, .oneTimeCode].contains($0) }),
            [.fill, .executeProgram, .read].contains(request.kind),
            (request.kind == .fill || request.fields.count == 1) else {
            throw LeaseFailure(.invalidArgument, "Supply a SHA-256 action digest, known operation kind and distinct credential fields.")
        }
        let key = request.requestID.isEmpty ? "digest:" + request.operationDigest.base64EncodedString() : "request:" + request.requestID
        var normalized = request
        normalized.fields.sort { $0.rawValue < $1.rawValue }
        var response = Agentkeyring_V1_BeginOperationResponse()
        if let saved = snapshot!.leases[lease.leaseID]!.operations[key] {
            guard try Agentkeyring_V1_BeginOperationRequest(serializedBytes: saved.request) == normalized else {
                throw LeaseFailure(.conflict, "That operation key was already used for a different action.")
            }
            let record = try Agentkeyring_V1_OperationRecord(serializedBytes: saved.record)
            response.operationID = record.operationID
            response.alreadyStarted = record
            return response
        }
        guard lease.state == .active else { throw LeaseFailure(.permissionDenied, "The lease is not active. Inspect its status before starting another request.") }
        guard (request.kind == .fill && lease.purpose == .browserSignIn)
            || (request.kind == .executeProgram && lease.purpose == .program)
            || (request.kind == .read && lease.purpose == .agentProcess) else {
            throw LeaseFailure(.permissionDenied, "This operation does not match the approved delivery purpose.")
        }
        // Resolve all fields before recording Started. No partial deliveries.
        let selectedValues = try values(lease, normalized.fields)
        var record = Agentkeyring_V1_OperationRecord()
        record.operationID = UUID().uuidString
        record.kind = request.kind
        record.startedUnixSeconds = Self.now
        var next = snapshot!
        next.leases[lease.leaseID]!.operations[key] = SavedOperation(request: try normalized.serializedData(), record: try record.serializedData())
        try commit(next)
        response.operationID = record.operationID
        response.values = selectedValues
        return response
    }

    public func operation(_ request: Agentkeyring_V1_GetOperationRequest) throws -> Agentkeyring_V1_GetOperationResponse {
        _ = try get(request.leaseID)
        guard request.operationDigest.count == 32 else {
            throw LeaseFailure(.invalidArgument, "Supply the SHA-256 action digest.")
        }
        let key = request.requestID.isEmpty ? "digest:" + request.operationDigest.base64EncodedString() : "request:" + request.requestID
        var response = Agentkeyring_V1_GetOperationResponse()
        if let saved = snapshot!.leases[request.leaseID]!.operations[key] {
            let original = try Agentkeyring_V1_BeginOperationRequest(serializedBytes: saved.request)
            guard original.operationDigest == request.operationDigest else {
                throw LeaseFailure(.conflict, "That operation key was already used for a different action.")
            }
            response.operation = try Agentkeyring_V1_OperationRecord(serializedBytes: saved.record)
        }
        return response
    }

    public func finish(_ request: Agentkeyring_V1_FinishOperationRequest) throws -> Agentkeyring_V1_OperationRecord {
        _ = try get(request.leaseID)
        guard let (key, saved) = snapshot!.leases[request.leaseID]!.operations.first(where: {
            (try? Agentkeyring_V1_OperationRecord(serializedBytes: $0.value.record).operationID) == request.operationID
        }) else { throw LeaseFailure(.notFound, "No such started operation.") }
        let original = try Agentkeyring_V1_OperationRecord(serializedBytes: saved.record)
        var finished = original
        switch (original.kind, request.outcome) {
        case let (.fill, .fill(outcome)) where outcome != .unspecified && !outcome.isUnknown:
            finished.fill = outcome
        case let (.executeProgram, .program(outcome)) where outcome != .unspecified && !outcome.isUnknown:
            guard request.hasExitCode == (outcome == .exited) else { throw LeaseFailure(.invalidArgument, "An exit code is required exactly when the program exited.") }
            finished.program = outcome
        case let (.read, .readDelivered(delivered)): finished.readDelivered = delivered
        default: throw LeaseFailure(.invalidArgument, "Supply a known outcome for the operation's kind.")
        }
        if request.hasExitCode {
            guard original.kind == .executeProgram else { throw LeaseFailure(.invalidArgument, "Only an exited program has an exit code.") }
            finished.exitCode = request.exitCode
        }
        if original.outcome != nil {
            guard original == finished else { throw LeaseFailure(.conflict, "This operation already has a different result.") }
            return original
        }
        var next = snapshot!
        next.leases[request.leaseID]!.operations[key]!.record = try finished.serializedData()
        try commit(next)
        return finished
    }

    public func expire() throws {
        guard let snapshot else { return }
        var next = snapshot
        for (id, saved) in snapshot.leases {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.state == .pending && lease.pendingUntilUnixSeconds <= Self.now {
                lease.state = .unanswered
                lease.endedAtUnixSeconds = lease.pendingUntilUnixSeconds
            }
            if lease.state == .active && lease.notAfterUnixSeconds <= Self.now {
                lease.state = .expired
                lease.endedAtUnixSeconds = lease.notAfterUnixSeconds
            }
            next.leases[id]!.lease = try lease.serializedData()
        }
        if next.leases.mapValues(\.lease) != snapshot.leases.mapValues(\.lease) { try commit(next) }
    }

    private func saveLease(_ lease: Agentkeyring_V1_Lease) throws {
        var next = snapshot!
        next.leases[lease.leaseID]!.lease = try lease.serializedData()
        try commit(next)
    }
    private func commit(_ next: Snapshot) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try persistence.save(encoder.encode(next))
        snapshot = next
        publish()
    }
    private func publish() {
        leases = (snapshot?.leases.values.compactMap { try? Agentkeyring_V1_Lease(serializedBytes: $0.lease) } ?? [])
            .sorted { $0.pendingUntilUnixSeconds > $1.pendingUntilUnixSeconds }
        for observer in observers.values { observer.yield(leases) }
    }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }
}

extension Agentkeyring_V1_FillOutcome {
    var isUnknown: Bool { if case .UNRECOGNIZED = self { true } else { false } }
}
extension Agentkeyring_V1_ProgramOutcome {
    var isUnknown: Bool { if case .UNRECOGNIZED = self { true } else { false } }
}
extension Agentkeyring_V1_LeaseState {
    public var isTerminal: Bool { self != .pending && self != .active }
}
