import AgentKeyringRelaySupport
import AgentKeyringProtocol
import Foundation
import Observation
import OSLog

private let historyLogger = Logger(subsystem: "com.agentkeyring.app", category: "TaskHistory")

public typealias LeaseFailure = RelayFailure

public struct CredentialLeaseRequester: Codable, Sendable {
    public let name: String
    public let workingDirectory: String?
    public let machineName: String
    public let networkAddress: String?
    /// The agent's claim: its Git repository's name.
    public let project: String?

    init(_ requester: AgentRequester, project: String) {
        name = requester.name
        workingDirectory = requester.workingDirectory
        machineName = requester.machineName
        networkAddress = requester.networkAddress
        self.project = project.isEmpty ? nil : project
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
    private struct SavedLease: Codable {
        var lease: Data
        var automatic: Bool
        var requester: CredentialLeaseRequester? = nil
    }
    /// After a denial the agent waits a minute before asking again; five after
    /// a second denial in a row, fifteen after more. An approval, or an hour
    /// with no denial, starts again at a minute. As the relay does for other computers.
    struct Suppression: Codable {
        var until: Int64
        var reply: String
        var inARow: Int?

        static func after(_ previous: Suppression?, reply: String, now: Int64) -> Suppression {
            let inARow = (previous.flatMap { now - $0.until <= 3600 ? ($0.inARow ?? 1) : nil } ?? 0) + 1
            let wait: Int64 = inARow == 1 ? 60 : inARow == 2 ? 300 : 900
            return Suppression(until: now + wait, reply: reply, inARow: inARow)
        }
    }

    /// What the agent reads while it waits: when it may ask again, and Josh's words.
    static func heldOff(_ until: Int64, reply: String) -> String {
        let time = Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .omitted, time: .standard)
        return "Josh denied this password. Ask again after \(time)." + (reply.isEmpty ? "" : " His reply, word for word: \"\(reply)\"")
    }
    private struct Snapshot: Codable {
        var version = 1
        var recipient: Data
        var leases: [String: SavedLease] = [:]
        var requests: [String: RequestRecord] = [:]
        var suppressions: [String: Suppression] = [:]
        /// Each waiting or approved lease this Mac also pushed to the iPhone and
        /// Apple Watch: lease ID to the signed request (Signed, serialized), so a
        /// restart takes their answers again. Optional, so older records still load.
        var pushed: [String: Data]? = nil
    }
    private var snapshot: Snapshot?
    private let persistence: LeasePersistence
    /// Each approved login, opened at approval and kept only in memory for
    /// its lease. Automatic leases open the Mac's own copy at each delivery.
    private var opened: [String: Agentkeyring_V2_LoginSecret] = [:]
    /// One-time codes the iPhone or Watch sent with an approval, which carries no seed.
    private var openedCodes: [String: [Agentkeyring_V2_TimedCode]] = [:]
    public private(set) var leases: [Agentkeyring_V1_Lease] = []
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: AsyncStream<[Agentkeyring_V1_Lease]>.Continuation] = [:]

    /// An agent on this Mac asked, or Josh answered: for the counts per password.
    public var onDecision: ((String, String, PasswordUsageLog.Event) -> Void)?

    public init(persistence: LeasePersistence = LeasePersistence()) {
        self.persistence = persistence
    }
    /// The requests waiting for an answer in this Mac's panel.
    public var waitingRequests: [Agentkeyring_V1_Lease] {
        leases.filter { $0.state == .pending }
    }
    public var activeLeases: [Agentkeyring_V1_Lease] { leases.filter { $0.state == .active } }

    public func load() throws {
        guard snapshot == nil else { return }
        var saved = try persistence.load().flatMap { bytes -> Snapshot? in
            guard let saved = try? PropertyListDecoder().decode(Snapshot.self, from: bytes), saved.version == 1 else {
                historyLogger.error("The record of agents' leases was unreadable; starting a new one.")
                return nil
            }
            return saved
        } ?? emptySnapshot()
        // A login opened for a lease is held only in memory, so a lease
        // approved before Agent Keyring last quit can no longer deliver.
        for (id, entry) in saved.leases where !entry.automatic {
            guard var lease = try? Agentkeyring_V1_Lease(serializedBytes: entry.lease), lease.state == .active else { continue }
            lease.state = .revoked
            lease.endedAtUnixSeconds = Self.now
            lease.statusLines = ["Agent Keyring restarted since this was approved. Ask again."]
            saved.leases[id]!.lease = try lease.serializedData()
        }
        try commit(saved)
        try expire()
    }

    private func emptySnapshot() -> Snapshot {
        var recipient = Agentkeyring_V1_Recipient()
        recipient.recipientID = UUID().uuidString
        recipient.machineLabel = Host.current().localizedName ?? "This Mac"
        recipient.clientLabel = "Local agents"
        return Snapshot(recipient: (try? recipient.serializedData()) ?? Data())
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
            !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LeaseFailure(.invalidArgument, "Supply a login, unique request ID, task and reason.")
        }
        request.loginID = loginID.uuidString
        let localRecipient = try recipient()
        guard request.recipientID.isEmpty || request.recipientID == localRecipient.recipientID else {
            throw LeaseFailure(.permissionDenied, "That recipient is not available to this local caller.")
        }
        request.recipientID = localRecipient.recipientID
        try expire()
        if let existing = snapshot!.requests[request.requestID] {
            guard try Agentkeyring_V1_RequestLeaseRequest(serializedBytes: existing.request) == request else {
                throw LeaseFailure(.conflict, "This request ID was already used with different contents.")
            }
            return try get(existing.leaseID)
        }
        guard let login, login.id == loginID else { throw LeaseFailure(.notFound, "The selected login is no longer available.") }
        var next = snapshot!
        if let joined = leases.first(where: {
            ($0.state == .pending || $0.state == .active) && $0.loginID == request.loginID
                && $0.taskRef == request.taskRef && $0.recipient.recipientID == request.recipientID
        }) {
            next.requests[request.requestID] = RequestRecord(request: try request.serializedData(), leaseID: joined.leaseID)
            try commit(next)
            return joined
        }
        let now = Self.now
        var lease = Agentkeyring_V1_Lease()
        lease.leaseID = UUID().uuidString
        lease.loginID = request.loginID
        lease.taskRef = request.taskRef
        lease.reason = request.reason
        lease.requestedAtUnixSeconds = now
        lease.recipient = localRecipient
        lease.sites = login.origins.sorted()
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
            lease.statusLines = [Self.heldOff(suppression.until, reply: suppression.reply)]
        } else if policy == .allowAutomatically {
            lease.state = .active
            lease.approvedBy = .automaticRule
            lease.approvedAtUnixSeconds = now
            lease.notAfterUnixSeconds = now + 1800
        } else {
            lease.state = .pending
            lease.statusLines = ["Waiting for approval in Agent Keyring."]
        }
        onDecision?(lease.leaseID, lease.loginID, .asked)
        if lease.state == .active { onDecision?(lease.leaseID, lease.loginID, .approved) }
        let saved = SavedLease(lease: try lease.serializedData(), automatic: policy == .allowAutomatically, requester: requester)
        next.leases[lease.leaseID] = saved
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

    /// Call only after Touch ID opened the login. Late or duplicate answers cannot revive a lease.
    func approve(_ leaseID: String, secret: Agentkeyring_V2_LoginSecret) throws -> Agentkeyring_V1_Lease {
        var lease = try get(leaseID)
        guard lease.state == .pending else { return lease }
        lease.state = .active
        lease.approvedBy = .mac
        let approvedAt = Self.now
        lease.approvedAtUnixSeconds = approvedAt
        lease.notAfterUnixSeconds = approvedAt + 1800
        lease.statusLines = []
        opened[leaseID] = secret
        try saveLease(lease)
        try forgetDenials(of: lease.loginID)
        onDecision?(leaseID, lease.loginID, .approved)
        DiagnosticLog.record("lease", "approved", ["lease": leaseID, "by": "mac"])
        return lease
    }

    /// An approval: the next denial holds the agent off for a minute again.
    private func forgetDenials(of loginID: String) throws {
        guard snapshot?.suppressions[loginID] != nil else { return }
        var next = snapshot!
        next.suppressions.removeValue(forKey: loginID)
        try commit(next)
    }

    /// The iPhone or Watch approved: what it sent, held in memory for the lease.
    func approveFromDevices(_ leaseID: String, contents: Agentkeyring_V2_DeliveryContents, by device: Agentkeyring_V1_ApprovedBy) throws {
        var lease = try get(leaseID)
        guard lease.state == .pending else { return }
        lease.state = .active
        lease.approvedBy = device
        lease.approvedAtUnixSeconds = Self.now
        lease.notAfterUnixSeconds = contents.notAfterUnixSeconds
        lease.statusLines = []
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = contents.loginID
        secret.username = contents.username
        secret.password = contents.password
        opened[leaseID] = secret
        openedCodes[leaseID] = contents.oneTimeCodes
        try saveLease(lease)
        try forgetDenials(of: lease.loginID)
        onDecision?(leaseID, lease.loginID, .approved)
        DiagnosticLog.record("lease", "approved", ["lease": leaseID, "by": "\(device)"])
    }

    /// The requests this Mac pushed for its agents' leases, by lease ID.
    var pushedRequests: [String: Data] { snapshot?.pushed ?? [:] }

    /// Remembers that this lease's request went to the iPhone and Apple Watch.
    func notePushed(_ leaseID: String, request: Data) throws {
        try load()
        var next = snapshot!
        next.pushed = (next.pushed ?? [:]).merging([leaseID: request]) { _, new in new }
        try commit(next)
    }

    /// The lease has ended and the devices were told: nothing more to take for it.
    func forgetPushed(_ leaseID: String) throws {
        guard snapshot?.pushed?[leaseID] != nil else { return }
        var next = snapshot!
        next.pushed?.removeValue(forKey: leaseID)
        try commit(next)
    }

    func openedCodes(for leaseID: String) -> [Agentkeyring_V2_TimedCode]? { openedCodes[leaseID] }

    /// The login opened for this lease; nil for an Automatic lease, which opens the Mac's own copy.
    func openedLogin(for leaseID: String) -> Agentkeyring_V2_LoginSecret? { opened[leaseID] }
    func isAutomatic(_ leaseID: String) -> Bool { snapshot?.leases[leaseID]?.automatic == true }

    public func deny(_ leaseID: String, reply: String = "", approvedBy: Agentkeyring_V1_ApprovedBy = .mac) throws -> Agentkeyring_V1_Lease {
        var lease = try get(leaseID)
        guard lease.state == .pending else { return lease }
        lease.state = .denied
        lease.reply = reply
        lease.approvedBy = approvedBy
        lease.endedAtUnixSeconds = Self.now
        var next = snapshot!
        let hold = Suppression.after(next.suppressions[lease.loginID], reply: reply, now: lease.endedAtUnixSeconds)
        lease.retryNotBeforeUnixSeconds = hold.until
        lease.statusLines = ["The request was denied."]
        next.suppressions[lease.loginID] = hold
        onDecision?(leaseID, lease.loginID, .denied)
        DiagnosticLog.record("lease", "denied", ["lease": leaseID, "by": "\(approvedBy)", "held_until": "\(hold.until)", "in_a_row": "\(hold.inARow ?? 1)"])
        next.leases[leaseID]!.lease = try lease.serializedData()
        // One denial covers this recipient/login, including already waiting tasks.
        for (id, saved) in next.leases where id != leaseID {
            var waiting = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if waiting.loginID == lease.loginID, waiting.state == .pending {
                waiting.state = .denied
                waiting.endedAtUnixSeconds = lease.endedAtUnixSeconds
                waiting.reply = reply
                waiting.approvedBy = approvedBy
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
        lease.statusLines = ["Josh stopped it."]
        try saveLease(lease)
        return lease
    }

    /// A new import may narrow destinations, never broaden an existing lease.
    public func reconcile(logins: [CredentialCandidate], policies: [UUID: CredentialAccessPolicy]) throws {
        try load()
        try expire()
        var next = snapshot!
        try reconcile(&next, logins: logins, policies: policies)
        if next.leases.mapValues(\.lease) != snapshot!.leases.mapValues(\.lease) { try commit(next) }
    }

    private func reconcile(_ next: inout Snapshot, logins: [CredentialCandidate],
        policies: [UUID: CredentialAccessPolicy]) throws {
        for (id, saved) in next.leases {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            guard lease.state == .pending || lease.state == .active else { continue }
            let login = logins.first { $0.id.uuidString == lease.loginID }
            let rule = login.map { policies[$0.id, default: .ask] }
            if login == nil || rule == .block || (saved.automatic && rule != .allowAutomatically) {
                lease.state = .revoked
                lease.statusLines = [login == nil ? "This password is no longer in Agent Keyring, so the lease ended."
                    : "Josh changed this password's rule, so the lease ended."]
            } else if let login, !lease.sites.isEmpty {
                // A password with no website (a server's, an app's) has no sites to narrow.
                lease.sites = lease.sites.filter { login.origins.contains($0) }
                if lease.sites.isEmpty {
                    lease.state = .revoked
                    lease.statusLines = ["This password's websites changed, so the lease ended."]
                }
            }
            if lease.state.isTerminal { lease.endedAtUnixSeconds = Self.now }
            next.leases[id]!.lease = try lease.serializedData()
        }
    }

    public func deliver(_ request: Agentkeyring_V1_DeliverRequest,
        values: (Agentkeyring_V1_Lease, [Agentkeyring_V1_CredentialField]) throws -> Agentkeyring_V1_CredentialValues
    ) throws -> Agentkeyring_V1_Delivery {
        let lease = try get(request.leaseID)
        guard !request.fields.isEmpty,
            Set(request.fields.map(\.rawValue)).count == request.fields.count,
            request.fields.allSatisfy({ [.username, .password, .oneTimeCode].contains($0) }),
            [.fill, .read].contains(request.kind),
            request.kind == .fill || request.fields.count == 1 else {
            throw LeaseFailure(.invalidArgument, "Supply a known operation kind and distinct credential fields.")
        }
        guard lease.state == .active else {
            throw LeaseFailure(.permissionDenied, "The lease is not active. Inspect its status before starting another request.")
        }
        var delivery = Agentkeyring_V1_Delivery()
        delivery.values = try values(lease, request.fields)
        return delivery
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
        next.leases = next.leases.filter { _, saved in
            guard let lease = try? Agentkeyring_V1_Lease(serializedBytes: saved.lease) else { return true }
            return !lease.state.isTerminal || lease.endedAtUnixSeconds + 7 * 86400 > Self.now
        }
        next.requests = next.requests.filter { next.leases[$0.value.leaseID] != nil }
        next.pushed = next.pushed?.filter { next.leases[$0.key] != nil }
        next.suppressions = next.suppressions.filter { $0.value.until > Self.now }
        if next.leases.mapValues(\.lease) != snapshot.leases.mapValues(\.lease)
            || next.suppressions.count != snapshot.suppressions.count { try commit(next) }
        else { scheduleDeadline() }
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
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        let deadlines = leases.map { lease in
            switch lease.state {
            case .pending: lease.pendingUntilUnixSeconds
            case .active: lease.notAfterUnixSeconds
            default: lease.endedAtUnixSeconds + 7 * 86400
            }
        } + (snapshot?.suppressions.values.map(\.until) ?? [])
        guard let deadline = deadlines.min() else { deadlineTask = nil; return }
        deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, Double(deadline) - Date().timeIntervalSince1970)))
                try Task.checkCancellation()
                try self?.expire()
            } catch is CancellationError { }
            catch {
                let native = error as NSError
                historyLogger.error("Task deadline save failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
            }
        }
    }
    private func publish() {
        let active = Set(snapshot?.leases.compactMap { id, entry in
            (try? Agentkeyring_V1_Lease(serializedBytes: entry.lease)).flatMap { $0.state == .active ? id : nil }
        } ?? [])
        opened = opened.filter { active.contains($0.key) }
        openedCodes = openedCodes.filter { active.contains($0.key) }
        leases = (snapshot?.leases.values.compactMap { try? Agentkeyring_V1_Lease(serializedBytes: $0.lease) } ?? [])
            .sorted { $0.pendingUntilUnixSeconds > $1.pendingUntilUnixSeconds }
        for observer in observers.values { observer.yield(leases) }
    }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }
}

extension Agentkeyring_V1_FillOutcome {
    var isUnknown: Bool { if case .UNRECOGNIZED = self { true } else { false } }
}
extension Agentkeyring_V1_LeaseState {
    public var isTerminal: Bool { self != .pending && self != .active }
}
