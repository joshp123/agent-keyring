import AgentKeyringProtocol
import Foundation

// Deadline work shares CredentialLeaseStore's single timer and checkpoint.
extension RelayApproverState {
    var hasPhone: Bool {
        guard let keySet, let signed = try? Agentkeyring_V1_SignedApproverKeySet(serializedBytes: keySet),
            let set = try? Agentkeyring_V1_ApproverKeySet(serializedBytes: signed.keySet) else { return false }
        return set.keys.contains { $0.role == .phone }
    }

    func canEscalate(loginID: String) -> Bool {
        guard hasPhone, let configuration,
            let signed = try? Agentkeyring_V1_SignedConfiguration(serializedBytes: configuration),
            let contents = try? Agentkeyring_V1_Configuration(serializedBytes: signed.configuration) else { return false }
        return contents.logins.contains { $0.loginID == loginID && $0.rule == .ask }
    }

    func enqueue(_ request: Agentkeyring_V1_RelayWireRequest, id: String, replacing: Bool = false) throws -> RelayApproverState {
        var next = self
        let bytes = try request.serializedData()
        if let index = next.outbox.firstIndex(where: { $0.id == id }) {
            if replacing { next.outbox[index].bytes = bytes }
            else if next.outbox[index].bytes != bytes { throw LeaseFailure(.conflict, "A different action is already queued.") }
        } else { next.outbox.append(RelayQueuedCommand(id: id, bytes: bytes)) }
        return next
    }

    var nextDeadline: Int64? {
        var deadlines = [Int64]()
        for saved in requests.values {
            guard let lease = try? Agentkeyring_V1_Lease(serializedBytes: saved.lease) else { continue }
            if lease.state.isTerminal { deadlines.append(lease.endedAtUnixSeconds + 7 * 86400) }
            else if lease.state == .active { deadlines.append(lease.notAfterUnixSeconds) }
            else {
                deadlines.append(saved.decision == nil || lease.notAfterUnixSeconds == 0
                    ? lease.pendingUntilUnixSeconds : lease.notAfterUnixSeconds)
                if canEscalate(loginID: lease.loginID), saved.decision == nil, saved.escalated != true, let due = saved.phoneDue { deadlines.append(due) }
            }
        }
        for saved in leaseReports?.values ?? Dictionary<String, RelaySavedLeaseReport>().values {
            guard let lease = try? Agentkeyring_V1_Lease(serializedBytes: saved.lease) else { continue }
            deadlines.append(lease.state.isTerminal ? lease.endedAtUnixSeconds + 7 * 86400
                : (lease.state == .active ? lease.notAfterUnixSeconds : lease.pendingUntilUnixSeconds))
        }
        for bytes in pendingEnrolments.values {
            if let record = try? Agentkeyring_V1_EnrolmentRecord(serializedBytes: bytes) { deadlines.append(record.createdUnixSeconds + 600) }
        }
        deadlines += pendingApproverCreated?.values.map { $0 + 600 } ?? []
        deadlines += suppressions.values.map { $0 }
        return deadlines.min()
    }

    mutating func maintain(now: Int64, screenLocked: Bool) throws {
        for (id, saved) in requests {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if saved.decision != nil || lease.state != .pending,
                let queued = outbox.first(where: { $0.id == "escalation:" + lease.leaseID }), queued.attempted != true {
                outbox.removeAll { $0.id == queued.id }
            }
            if lease.state == .pending && (saved.decision == nil || lease.notAfterUnixSeconds == 0) && lease.pendingUntilUnixSeconds <= now {
                lease.state = .unanswered
                lease.endedAtUnixSeconds = lease.pendingUntilUnixSeconds
            } else if !lease.state.isTerminal, lease.notAfterUnixSeconds > 0, lease.notAfterUnixSeconds <= now {
                lease.state = .expired
                lease.endedAtUnixSeconds = lease.notAfterUnixSeconds
            }
            if lease.state.isTerminal {
                if lease.endedAtUnixSeconds + 7 * 86400 <= now { requests.removeValue(forKey: id) }
                else {
                    requests[id]!.lease = try lease.serializedData()
                    if saved.acknowledged || lease.state != .unanswered { requests[id]!.decision = nil }
                    requests[id]!.phoneDue = nil
                }
                outbox.removeAll { ($0.id == "decision:" + id && (saved.acknowledged || lease.state != .unanswered))
                    || $0.id == "escalation:" + lease.leaseID }
            } else if canEscalate(loginID: lease.loginID), saved.decision == nil, saved.escalated != true,
                let due = saved.phoneDue, screenLocked || due <= now {
                var command = Agentkeyring_V1_RelayWireRequest()
                command.escalateToPhone.leaseID = lease.leaseID
                command.escalateToPhone.record = saved.record
                self = try enqueue(command, id: "escalation:" + lease.leaseID)
                requests[id]!.escalated = true
            }
        }
        for (id, saved) in leaseReports ?? [:] {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.state.isTerminal {
                if lease.endedAtUnixSeconds + 7 * 86400 <= now { leaseReports?.removeValue(forKey: id) }
            } else if (lease.state == .active ? lease.notAfterUnixSeconds : lease.pendingUntilUnixSeconds) <= now {
                lease.endedAtUnixSeconds = lease.state == .active ? lease.notAfterUnixSeconds : lease.pendingUntilUnixSeconds
                lease.state = lease.state == .active ? .expired : .unanswered
                leaseReports![id]!.lease = try lease.serializedData()
            }
        }
        pendingEnrolments = pendingEnrolments.filter {
            (try? Agentkeyring_V1_EnrolmentRecord(serializedBytes: $0.value).createdUnixSeconds + 600 > now) == true
        }
        for (id, created) in pendingApproverCreated ?? [:] where created + 600 <= now {
            pendingApprovers?.removeValue(forKey: id)
            pendingApproverCreated?.removeValue(forKey: id)
        }
        suppressions = suppressions.filter { $0.value > now }
    }
}
