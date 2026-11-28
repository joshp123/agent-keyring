#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import OSLog
import Observation

private let historyLogger = Logger(subsystem: "com.agentkeyring.app", category: "TaskHistory")

public struct CredentialLeaseRequester: Sendable {
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

    init(storedProto proto: Agentkeyring_V2_StoredLeaseRequester) {
        name = proto.name
        workingDirectory = proto.hasWorkingDirectory ? proto.workingDirectory : nil
        machineName = proto.machineName
        networkAddress = proto.hasNetworkAddress ? proto.networkAddress : nil
        project = proto.hasProject ? proto.project : nil
    }

    func storedProto() -> Agentkeyring_V2_StoredLeaseRequester {
        var proto = Agentkeyring_V2_StoredLeaseRequester()
        proto.name = name
        if let workingDirectory { proto.workingDirectory = workingDirectory }
        proto.machineName = machineName
        if let networkAddress { proto.networkAddress = networkAddress }
        if let project { proto.project = project }
        return proto
    }
}

/// Authority methods run synchronously on the main actor: the durable commit
/// precedes publication and value delivery, with no suspension between them.
@MainActor @Observable
public final class CredentialLeaseStore {
    /// After a denial the agent waits a minute before asking again; five after
    /// a second denial in a row, fifteen after more. An approval, or an hour
    /// with no denial, starts again at a minute. As the relay does for other computers.
    struct Suppression {
        var until: Int64
        var reply: String
        var inARow: Int

        static func after(_ previous: Suppression?, reply: String, now: Int64) -> Suppression {
            let inARow = (previous.flatMap { now - $0.until <= 3600 ? $0.inARow : nil } ?? 0) + 1
            let wait: Int64 = inARow == 1 ? 60 : inARow == 2 ? 300 : 900
            return Suppression(until: now + wait, reply: reply, inARow: inARow)
        }
    }

    /// What the agent reads while it waits: when it may ask again, and Josh's words.
    static func heldOff(_ until: Int64, reply: String) -> String {
        let time = Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .omitted, time: .standard)
        return "The user denied this password. Ask again after \(time)." + (reply.isEmpty ? "" : " Their reply, word for word: \"\(reply)\"")
    }
    private var snapshot: Snapshot?
    private let persistence: LeasePersistence
    /// Each approved login, opened at approval and kept only in memory for
    /// its lease. Automatic leases open the Mac's own copy at each delivery.
    private var opened: [String: Agentkeyring_V2_LoginSecret] = [:]
    /// One-time codes the iPhone or Watch sent with an approval, which carries no seed.
    private var openedCodes: [String: [Agentkeyring_V2_TimedCode]] = [:]
    public private(set) var leases: [Agentkeyring_V2_Lease] = []
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: AsyncStream<[Agentkeyring_V2_Lease]>.Continuation] = [:]

    /// An agent on this Mac asked, or Josh answered: for the counts per password.
    var onDecision: ((String, String, PasswordUsageEvent) -> Void)?

    public init(persistence: LeasePersistence = LeasePersistence()) {
        self.persistence = persistence
    }
    /// The requests waiting for an answer in this Mac's panel.
    public var waitingRequests: [Agentkeyring_V2_Lease] {
        leases.filter { $0.state == .waiting }
    }
    public var activeLeases: [Agentkeyring_V2_Lease] { leases.filter { $0.state == .approved } }

    public func loadLeaseRecords() throws {
        guard snapshot == nil else { return }
        var saved: Snapshot
        do {
            saved = try persistence.load() ?? emptySnapshot()
        } catch {
            historyLogger.error("The record of agents' leases could not be read; it is not written over: \(String(describing: error), privacy: .public)")
            throw error
        }
        // A login opened for a lease is held only in memory, so a lease
        // approved before Agent Keyring last quit can no longer deliver.
        for (id, entry) in saved.leases where !entry.lease.automatic {
            var lease = entry.lease
            guard lease.state == .approved else { continue }
            lease.state = .ended
            lease.endedAtUnixSeconds = Self.now
            lease.authorityContext.statusLines = ["Agent Keyring restarted since this was approved. Ask again."]
            saved.leases[id]!.lease = lease
        }
        try commit(saved)
        try expire()
    }

    /// Removes all saved leases, requests, and suppressions in memory and on disk.
    func clearLeaseRecords() throws {
        deadlineTask?.cancel()
        deadlineTask = nil
        opened.removeAll()
        openedCodes.removeAll()
        snapshot = emptySnapshot()
        leases = []
        try persistence.clearSavedLeases()
        for observer in observers.values { observer.yield([]) }
    }

    private func emptySnapshot() -> Snapshot {
        var recipient = Agentkeyring_V2_Recipient()
        recipient.recipientID = UUID().uuidString
        recipient.machineLabel = Host.current().localizedName ?? "This Mac"
        recipient.clientLabel = "Local agents"
        return Snapshot(recipient: recipient)
    }

    public func changes() -> AsyncStream<[Agentkeyring_V2_Lease]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[Agentkeyring_V2_Lease]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(leases)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.observers.removeValue(forKey: id) }
        }
        return stream
    }

    public func recipient() throws -> Agentkeyring_V2_Recipient {
        try loadLeaseRecords()
        return snapshot!.recipient
    }

    /// The bridge has authenticated the local OS peer. Release 2 deliberately
    /// has one principal/recipient for that OS user, independent of process IDs.
    public func recordLeaseRequest(_ incoming: Agentkeyring_V2_RequestLeaseRequest, login: CredentialCandidate?,
        rule: LoginRule, requester: CredentialLeaseRequester? = nil) throws -> Agentkeyring_V2_Lease {
        try loadLeaseRecords()
        var request = incoming
        guard let loginID = UUID(uuidString: request.loginID), !request.requestID.isEmpty,
            !request.taskRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentRPCError(.invalidArgument, "Supply a login, unique request ID, task and reason.")
        }
        request.loginID = loginID.uuidString
        let localRecipient = try recipient()
        guard request.recipientID.isEmpty || request.recipientID == localRecipient.recipientID else {
            throw AgentRPCError(.permissionDenied, "That recipient is not available to this local caller.")
        }
        request.recipientID = localRecipient.recipientID
        try expire()
        if let existing = snapshot!.requests[request.requestID] {
            guard existing.request == request else {
                throw AgentRPCError(.conflict, "This request ID was already used with different contents.")
            }
            return try get(existing.leaseID)
        }
        guard let login, login.id == loginID else { throw AgentRPCError(.notFound, "The selected login is no longer available.") }
        var next = snapshot!
        if let joined = leases.first(where: {
            ($0.state == .waiting || $0.state == .approved) && $0.loginID == request.loginID
                && $0.authorityContext.taskRef == request.taskRef && $0.authorityContext.recipient.recipientID == request.recipientID
        }) {
            next.requests[request.requestID] = RequestRecord(request: request, leaseID: joined.requestID)
            try commit(next)
            return joined
        }
        let now = Self.now
        var lease = Agentkeyring_V2_Lease()
        lease.requestID = UUID().uuidString
        lease.loginID = request.loginID
        lease.authorityContext.taskRef = request.taskRef
        lease.authorityContext.reason = request.reason
        lease.requestedAtUnixSeconds = now
        lease.authorityContext.recipient = localRecipient
        lease.authorityContext.sites = login.origins.sorted()
        lease.answerByUnixSeconds = now + 600
        if rule == .blocked {
            lease.state = .denied
            lease.endedAtUnixSeconds = now
            lease.authorityContext.statusLines = ["This login is blocked in Agent Keyring."]
        } else if let suppression = next.suppressions[request.loginID], suppression.until > now {
            lease.state = .denied
            lease.endedAtUnixSeconds = now
            lease.retryNotBeforeUnixSeconds = suppression.until
            lease.reply = suppression.reply
            lease.authorityContext.statusLines = [Self.heldOff(suppression.until, reply: suppression.reply)]
        } else if rule == .automatic {
            lease.state = .approved
            lease.automatic = true
            lease.approvedAtUnixSeconds = now
            lease.notAfterUnixSeconds = now + 1800
        } else {
            lease.state = .waiting
            lease.authorityContext.statusLines = ["Waiting for approval in Agent Keyring."]
        }
        onDecision?(lease.requestID, lease.loginID, .asked)
        if lease.state == .approved { onDecision?(lease.requestID, lease.loginID, .approved) }
        let saved = SavedLease(lease: lease, requester: requester)
        next.leases[lease.requestID] = saved
        next.requests[request.requestID] = RequestRecord(request: request, leaseID: lease.requestID)
        try commit(next)
        return lease
    }

    public func requester(for leaseID: String) -> CredentialLeaseRequester? { snapshot?.leases[leaseID]?.requester }

    public func get(_ leaseID: String) throws -> Agentkeyring_V2_Lease {
        try loadLeaseRecords()
        try expire()
        guard let saved = snapshot!.leases[leaseID] else { throw AgentRPCError(.notFound, "No such lease.") }
        return saved.lease
    }

    /// Call only after Touch ID opened the login. Late or duplicate answers cannot revive a lease.
    func approve(_ leaseID: String, secret: Agentkeyring_V2_LoginSecret) throws -> Agentkeyring_V2_Lease {
        var lease = try get(leaseID)
        guard lease.state == .waiting else { return lease }
        lease.state = .approved
        lease.authorityContext.decidingDeviceKind = .mac
        let approvedAt = Self.now
        lease.approvedAtUnixSeconds = approvedAt
        lease.notAfterUnixSeconds = approvedAt + 1800
        lease.authorityContext.statusLines = []
        opened[leaseID] = secret
        try saveLease(lease)
        try forgetDenials(of: lease.loginID)
        onDecision?(leaseID, lease.loginID, .approved)
        KeyringDiagnosticLog.mac.noteDeviceEvent("lease", "approved", ["lease": leaseID, "by": "mac"])
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
    func approveFromDevices(_ leaseID: String, contents: Agentkeyring_V2_DeliveryContents, by device: Agentkeyring_V2_DeviceKind) throws {
        var lease = try get(leaseID)
        guard lease.state == .waiting else { return }
        lease.state = .approved
        lease.authorityContext.decidingDeviceKind = device
        lease.approvedAtUnixSeconds = Self.now
        lease.notAfterUnixSeconds = contents.notAfterUnixSeconds
        lease.authorityContext.statusLines = []
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = contents.loginID
        secret.username = contents.username
        secret.password = contents.password
        opened[leaseID] = secret
        openedCodes[leaseID] = contents.oneTimeCodes
        try saveLease(lease)
        try forgetDenials(of: lease.loginID)
        onDecision?(leaseID, lease.loginID, .approved)
        KeyringDiagnosticLog.mac.noteDeviceEvent("lease", "approved", ["lease": leaseID, "by": "\(device)"])
    }

    /// The requests this Mac pushed for its agents' leases, by lease ID.
    var pushedRequests: [String: Data] { snapshot?.pushed ?? [:] }

    /// Remembers that this lease's request went to the iPhone and Apple Watch.
    func notePushed(_ leaseID: String, request: Data) throws {
        try loadLeaseRecords()
        var next = snapshot!
        next.pushed[leaseID] = request
        try commit(next)
    }

    /// The pushed leases whose grant the relay took.
    var grantsPut: Set<String> { snapshot?.grantsPut ?? [] }

    /// Remembers that this lease's grant is at the relay.
    func noteGrantPut(_ leaseID: String) throws {
        try loadLeaseRecords()
        guard snapshot?.grantsPut.contains(leaseID) != true else { return }
        var next = snapshot!
        next.grantsPut.insert(leaseID)
        try commit(next)
    }

    /// The lease has ended and the devices were told: nothing more to take for it.
    func forgetPushed(_ leaseID: String) throws {
        guard snapshot?.pushed[leaseID] != nil || snapshot?.grantsPut.contains(leaseID) == true else { return }
        var next = snapshot!
        next.pushed.removeValue(forKey: leaseID)
        next.grantsPut.remove(leaseID)
        try commit(next)
    }

    func openedCodes(for leaseID: String) -> [Agentkeyring_V2_TimedCode]? { openedCodes[leaseID] }

    /// The login opened for this lease; nil for an Automatic lease, which opens the Mac's own copy.
    func openedLogin(for leaseID: String) -> Agentkeyring_V2_LoginSecret? { opened[leaseID] }

    public func denyLease(_ leaseID: String, reply: String = "", decidedOn: Agentkeyring_V2_DeviceKind = .mac) throws -> Agentkeyring_V2_Lease {
        var lease = try get(leaseID)
        guard lease.state == .waiting else { return lease }
        lease.state = .denied
        lease.reply = reply
        lease.authorityContext.decidingDeviceKind = decidedOn
        lease.endedAtUnixSeconds = Self.now
        var next = snapshot!
        let hold = Suppression.after(next.suppressions[lease.loginID], reply: reply, now: lease.endedAtUnixSeconds)
        lease.retryNotBeforeUnixSeconds = hold.until
        lease.authorityContext.statusLines = ["The request was denied."]
        next.suppressions[lease.loginID] = hold
        onDecision?(leaseID, lease.loginID, .denied)
        KeyringDiagnosticLog.mac.noteDeviceEvent("lease", "denied", ["lease": leaseID, "by": "\(decidedOn)", "held_until": "\(hold.until)", "in_a_row": "\(hold.inARow)"])
        next.leases[leaseID]!.lease = lease
        // One denial covers this recipient/login, including already waiting tasks.
        for (id, saved) in next.leases where id != leaseID {
            var waiting = saved.lease
            if waiting.loginID == lease.loginID, waiting.state == .waiting {
                waiting.state = .denied
                waiting.endedAtUnixSeconds = lease.endedAtUnixSeconds
                waiting.reply = reply
                waiting.authorityContext.decidingDeviceKind = decidedOn
                waiting.retryNotBeforeUnixSeconds = lease.retryNotBeforeUnixSeconds
                next.leases[id]!.lease = waiting
            }
        }
        try commit(next)
        return lease
    }

    public func clearDenial(loginID: String) throws {
        try loadLeaseRecords()
        var next = snapshot!
        let normalizedID = UUID(uuidString: loginID)?.uuidString ?? loginID
        next.suppressions.removeValue(forKey: normalizedID)
        for (id, saved) in next.leases {
            var lease = saved.lease
            if lease.loginID == normalizedID, lease.state == .denied, lease.retryNotBeforeUnixSeconds != 0 {
                lease.retryNotBeforeUnixSeconds = 0
                next.leases[id]!.lease = lease
            }
        }
        try commit(next)
    }

    @discardableResult public func end(_ leaseID: String) throws -> Agentkeyring_V2_Lease {
        var lease = try get(leaseID)
        if lease.state == .waiting { lease.state = .cancelled }
        else if lease.state == .approved { lease.state = .released }
        else { return lease }
        lease.endedAtUnixSeconds = Self.now
        try saveLease(lease)
        return lease
    }

    /// Josh ended access. This is distinct from the agent finishing its task.
    @discardableResult public func revoke(_ leaseID: String) throws -> Agentkeyring_V2_Lease {
        var lease = try get(leaseID)
        guard !lease.state.isTerminal else { return lease }
        lease.state = .ended
        lease.endedAtUnixSeconds = Self.now
        lease.authorityContext.statusLines = ["The user stopped it."]
        try saveLease(lease)
        return lease
    }

    /// A new import may narrow destinations, never broaden an existing lease.
    public func reconcile(logins: [CredentialCandidate], rules: [UUID: LoginRule]) throws {
        try loadLeaseRecords()
        try expire()
        var next = snapshot!
        for (id, saved) in next.leases {
            var lease = saved.lease
            guard lease.state == .waiting || lease.state == .approved else { continue }
            let login = logins.first { $0.id.uuidString == lease.loginID }
            let rule = login.map { rules[$0.id, default: .ask] }
            if login == nil || rule == .blocked || (lease.automatic && rule != .automatic) {
                lease.state = .ended
                lease.authorityContext.statusLines = [login == nil ? "This password is no longer in Agent Keyring, so the lease ended."
                    : "The user changed this password's rule, so the lease ended."]
            } else if let login, !lease.authorityContext.sites.isEmpty {
                // A password with no website (a server's, an app's) has no sites to narrow.
                lease.authorityContext.sites = lease.authorityContext.sites.filter { login.origins.contains($0) }
                if lease.authorityContext.sites.isEmpty {
                    lease.state = .ended
                    lease.authorityContext.statusLines = ["This password's websites changed, so the lease ended."]
                }
            }
            if lease.state.isTerminal { lease.endedAtUnixSeconds = Self.now }
            next.leases[id]!.lease = lease
        }
        if next.leases.mapValues(\.lease) != snapshot!.leases.mapValues(\.lease) { try commit(next) }
    }

    public func deliver(_ request: Agentkeyring_V2_DeliverRequest,
        values: (Agentkeyring_V2_Lease, [Agentkeyring_V2_CredentialField]) throws -> Agentkeyring_V2_CredentialValues
    ) throws -> Agentkeyring_V2_LocalCredentialDelivery {
        let lease = try get(request.leaseID)
        guard !request.fields.isEmpty,
            Set(request.fields.map(\.rawValue)).count == request.fields.count,
            request.fields.allSatisfy({ [.username, .password, .oneTimeCode].contains($0) }),
            [.fill, .read].contains(request.kind),
            request.kind == .fill || request.fields.count == 1 else {
            throw AgentRPCError(.invalidArgument, "Supply a known operation kind and distinct credential fields.")
        }
        guard lease.state == .approved else {
            throw AgentRPCError(.permissionDenied, "The lease is not active. Inspect its status before starting another request.")
        }
        var delivery = Agentkeyring_V2_LocalCredentialDelivery()
        delivery.values = try values(lease, request.fields)
        return delivery
    }

    func expire() throws {
        guard let snapshot else { return }
        var next = snapshot
        for (id, saved) in snapshot.leases {
            var lease = saved.lease
            if lease.state == .waiting && lease.answerByUnixSeconds <= Self.now {
                lease.state = .unanswered
                lease.endedAtUnixSeconds = lease.answerByUnixSeconds
            }
            if lease.state == .approved && lease.notAfterUnixSeconds <= Self.now {
                lease.state = .expired
                lease.endedAtUnixSeconds = lease.notAfterUnixSeconds
            }
            next.leases[id]!.lease = lease
        }
        next.leases = next.leases.filter { _, saved in
            let lease = saved.lease
            return !lease.state.isTerminal || lease.endedAtUnixSeconds + 7 * 86400 > Self.now
        }
        next.requests = next.requests.filter { next.leases[$0.value.leaseID] != nil }
        next.pushed = next.pushed.filter { next.leases[$0.key] != nil }
        next.grantsPut = next.grantsPut.filter { next.leases[$0] != nil }
        next.suppressions = next.suppressions.filter { $0.value.until > Self.now }
        if next.leases.mapValues(\.lease) != snapshot.leases.mapValues(\.lease)
            || next.suppressions.count != snapshot.suppressions.count { try commit(next) }
        else { scheduleDeadline() }
    }

    private func saveLease(_ lease: Agentkeyring_V2_Lease) throws {
        var next = snapshot!
        next.leases[lease.requestID]!.lease = lease
        try commit(next)
    }
    private func commit(_ next: Snapshot) throws {
        try persistence.save(next)
        snapshot = next
        publish()
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        let deadlines = leases.map { lease in
            switch lease.state {
            case .waiting: lease.answerByUnixSeconds
            case .approved: lease.notAfterUnixSeconds
            case .ended, .denied, .expired, .released, .cancelled, .unanswered, .unspecified, .UNRECOGNIZED:
                lease.endedAtUnixSeconds + 7 * 86400
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
            entry.lease.state == .approved ? id : nil
        } ?? [])
        opened = opened.filter { active.contains($0.key) }
        openedCodes = openedCodes.filter { active.contains($0.key) }
        leases = (snapshot?.leases.values.map(\.lease) ?? [])
            .sorted { $0.answerByUnixSeconds > $1.answerByUnixSeconds }
        for observer in observers.values { observer.yield(leases) }
    }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }
}

extension Agentkeyring_V2_FillOutcome {
    var isUnknown: Bool { if case .UNRECOGNIZED = self { true } else { false } }
}
#endif
