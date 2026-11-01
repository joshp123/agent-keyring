// Written by AI on 2026.11.01 by model gpt-6.1-sol.
import AgentKeyringProtocol
import Foundation

extension PhoneApproverState {
    // Match the Mac and relay: seven days after completion, never while an
    // answer is awaiting acknowledgement. Trust receipts live in the outbox.
    static let historySeconds: Int64 = 7 * 86400

    private func completionTime(_ lease: Agentkeyring_V1_Lease) -> Int64 {
        switch lease.state {
        case .pending: return lease.pendingUntilUnixSeconds
        case .active: return lease.notAfterUnixSeconds
        default:
            return max(lease.endedAtUnixSeconds, lease.requestedAtUnixSeconds,
                       lease.retryNotBeforeUnixSeconds)
        }
    }

    // Times come from the relay, so a far-future value must not overflow.
    private func historyEnd(_ lease: Agentkeyring_V1_Lease) -> Int64 {
        let (end, overflow) = completionTime(lease).addingReportingOverflow(Self.historySeconds)
        return overflow ? .max : end
    }

    mutating func pruneHistory(now: Int64) throws {
        var retainedLeaseIDs = Set<String>()
        for (id, saved) in requests {
            let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if (!saved.hasAnswer || saved.acknowledged) && historyEnd(lease) <= now {
                requests.removeValue(forKey: id)
            } else { retainedLeaseIDs.insert(lease.leaseID) }
        }
        for (id, bytes) in remoteLeases {
            let lease = try Agentkeyring_V1_Lease(serializedBytes: bytes)
            if !retainedLeaseIDs.contains(id) && historyEnd(lease) <= now {
                remoteLeases.removeValue(forKey: id)
            }
        }
    }

    func nextHistoryDeadline(now: Int64) throws -> Int64? {
        var deadline: Int64?
        func include(_ candidate: Int64) {
            if candidate > now { deadline = min(deadline ?? candidate, candidate) }
        }
        for saved in requests.values {
            let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.state == .pending || lease.state == .active { include(completionTime(lease)) }
            if !saved.hasAnswer || saved.acknowledged { include(historyEnd(lease)) }
        }
        for bytes in remoteLeases.values {
            let lease = try Agentkeyring_V1_Lease(serializedBytes: bytes)
            if lease.state == .pending || lease.state == .active { include(completionTime(lease)) }
            include(historyEnd(lease))
        }
        return deadline
    }
}

extension PhoneRelayApprover {
    func scheduleHistoryDeadline() {
        historyTask?.cancel(); historyTask = nil
        guard running else { return }
        do {
            guard let deadline = try state.nextHistoryDeadline(now: Self.now) else { return }
            historyTask = Task { [weak self] in
                // Wake at least daily; commit reschedules for anything later.
                let wait = min(max(1, deadline - Self.now), 86400)
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                guard let self else { return }
                self.historyTask = nil
                do { try self.commit(self.state) } catch { self.fail(error, stage: "Prune request history") }
            }
        } catch { fail(error, stage: "Schedule request history") }
    }

    func scheduleOutboxRetry() {
        guard running, !state.outbox.isEmpty else {
            retryTask?.cancel(); retryTask = nil
            return
        }
        guard !flushing, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            await self.flushOutbox()
        }
    }
}
