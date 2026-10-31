import AgentKeyringProtocol
import Foundation

extension RelayApprover {
    static func isTerminal(_ state: Agentkeyring_V1_LeaseState) -> Bool {
        [.denied, .expired, .released, .revoked, .cancelled, .unanswered].contains(state)
    }

    // Reports feed the screen, never the decision or credential-delivery path.
    func receiveLeaseReport(_ report: Agentkeyring_V1_Lease) async throws {
        guard !report.leaseID.isEmpty, UUID(uuidString: report.loginID) != nil,
            let machineBytes = state.machines[report.recipient.recipientID],
            report.state == .pending || report.state == .active || Self.isTerminal(report.state) else {
            throw LeaseFailure(.invalidArgument, "The relay reported an unknown login, machine or lease state.")
        }
        let existing = state.requests.values.first { (try? Agentkeyring_V1_Lease(serializedBytes: $0.lease).leaseID) == report.leaseID }
        var lease = report
        let title: String
        let account: String
        if let existing {
            let own = try Agentkeyring_V1_Lease(serializedBytes: existing.lease)
            guard own.loginID == report.loginID, own.taskRef == report.taskRef, own.purpose == report.purpose,
                own.recipient.recipientID == report.recipient.recipientID, own.program == report.program else {
                throw LeaseFailure(.conflict, "The reported lease differs from its original request.")
            }
            lease = own
            if !Self.isTerminal(own.state) || own.state == .cancelled {
                lease.state = report.state
                lease.approvedAtUnixSeconds = report.approvedAtUnixSeconds
                lease.notAfterUnixSeconds = report.notAfterUnixSeconds
                lease.endedAtUnixSeconds = report.endedAtUnixSeconds
                lease.approvedBy = report.approvedBy
                lease.retryNotBeforeUnixSeconds = report.retryNotBeforeUnixSeconds
            }
            if own.state == .denied, report.state == .denied, report.retryNotBeforeUnixSeconds == 0 {
                lease.retryNotBeforeUnixSeconds = 0
            }
            title = existing.title
            account = existing.account
        } else {
            let vault = try await credentialSource()
            guard state.machines[report.recipient.recipientID] == machineBytes,
                let item = vault.generation.items.first(where: { $0.id == UUID(uuidString: report.loginID) }) else {
                throw LeaseFailure(.notFound, "The reported login or machine is no longer available on this Mac.")
            }
            lease.sites = item.origins
            title = item.title
            account = CredentialResolver().candidate(for: item).username ?? ""
        }
        let machine = try Agentkeyring_V1_EnrolledMachine(serializedBytes: machineBytes)
        lease.recipient.machineLabel = machine.machineLabel
        lease.recipient.clientLabel = machine.clientLabel
        if let previous = state.leaseReports?[lease.leaseID] {
            let old = try Agentkeyring_V1_Lease(serializedBytes: previous.lease)
            guard old.loginID == lease.loginID, old.recipient.recipientID == lease.recipient.recipientID,
                old.taskRef == lease.taskRef, old.purpose == lease.purpose, old.program == lease.program else {
                throw LeaseFailure(.conflict, "The relay changed a reported lease's scope.")
            }
            if Self.isTerminal(old.state) {
                guard old.state == .denied, lease.state == .denied, lease.retryNotBeforeUnixSeconds == 0 else { return }
            }
            if old.state == .active && lease.state == .pending { return }
            if old.notAfterUnixSeconds > 0 { lease.notAfterUnixSeconds = min(old.notAfterUnixSeconds, lease.notAfterUnixSeconds) }
        }
        if lease.state == .active {
            guard lease.approvedAtUnixSeconds > 0, lease.notAfterUnixSeconds > lease.approvedAtUnixSeconds,
                lease.notAfterUnixSeconds - lease.approvedAtUnixSeconds <= 1800 else {
                throw LeaseFailure(.invalidArgument, "The reported lease exceeds its approval deadline.")
            }
            if lease.notAfterUnixSeconds <= Self.now { lease.state = .expired; lease.endedAtUnixSeconds = Self.now }
        }
        var next = state
        if next.leaseReports == nil { next.leaseReports = [:] }
        next.leaseReports![lease.leaseID] = RelaySavedLeaseReport(lease: try lease.serializedData(), title: title,
            account: account, machine: machineBytes)
        // Another approver's answer closes the local prompt without creating
        // a local decision or treating its metadata as credential authority.
        if lease.state != .pending {
            for (id, saved) in next.requests where saved.decision == nil {
                var pending = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
                if pending.leaseID == lease.leaseID, pending.state == .pending {
                    pending.state = lease.state
                    pending.approvedAtUnixSeconds = lease.approvedAtUnixSeconds
                    pending.notAfterUnixSeconds = lease.notAfterUnixSeconds
                    pending.approvedBy = lease.approvedBy
                    pending.endedAtUnixSeconds = lease.endedAtUnixSeconds
                    next.requests[id]!.lease = try pending.serializedData()
                }
            }
        }
        try commit(next)
    }

    func expireLeaseReports(_ next: inout RelayApproverState) throws -> Bool {
        var changed = false
        for (id, saved) in next.leaseReports ?? [:] {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.state == .active, lease.notAfterUnixSeconds <= Self.now { lease.state = .expired }
            else if lease.state == .pending, lease.pendingUntilUnixSeconds <= Self.now { lease.state = .unanswered }
            else { continue }
            lease.endedAtUnixSeconds = Self.now
            next.leaseReports![id]!.lease = try lease.serializedData()
            changed = true
        }
        return changed
    }

    func clearReportedDenial(loginID: String, recipientID: String, next: inout RelayApproverState) throws {
        for (id, saved) in next.leaseReports ?? [:] {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.loginID == loginID, lease.recipient.recipientID == recipientID, lease.state == .denied {
                lease.retryNotBeforeUnixSeconds = 0
                next.leaseReports![id]!.lease = try lease.serializedData()
            }
        }
    }

    public func revokeLease(_ leaseID: String) async throws {
        try load()
        guard let displayed = leases.first(where: { $0.id == leaseID }) else {
            throw LeaseFailure(.notFound, "No such remote lease.")
        }
        let queuedID = "revoke-lease:" + leaseID
        if state.outbox.contains(where: { $0.id == queuedID }) { await flushOutbox(); return }
        guard displayed.lease.state == .active || displayed.lease.state == .pending else { return }
        var next = state
        var lease = displayed.lease
        lease.state = .revoked
        lease.endedAtUnixSeconds = Self.now
        if next.leaseReports == nil { next.leaseReports = [:] }
        next.leaseReports![leaseID] = RelaySavedLeaseReport(lease: try lease.serializedData(), title: displayed.loginTitle,
            account: displayed.account, machine: try displayed.machine.serializedData())
        for (id, saved) in next.requests {
            if try Agentkeyring_V1_Lease(serializedBytes: saved.lease).leaseID == leaseID {
                next.requests[id]!.lease = try lease.serializedData()
                next.outbox.removeAll { $0.id == "decision:" + id }
            }
        }
        var command = Agentkeyring_V1_RelayWireRequest()
        command.revokeLease.leaseID = leaseID
        try enqueue(command, id: queuedID, into: &next)
        try commit(next)
        await flushOutbox()
    }
}
