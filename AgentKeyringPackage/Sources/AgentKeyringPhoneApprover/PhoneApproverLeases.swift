import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation

extension PhoneRelayApprover {
    func receiveLease(_ lease: Agentkeyring_V1_Lease) throws {
        guard !lease.leaseID.isEmpty, !lease.loginID.isEmpty, !lease.recipient.recipientID.isEmpty,
              [.pending, .active, .denied, .released, .revoked, .expired, .cancelled, .unanswered].contains(lease.state) else {
            throw RelayFailure(.invalidArgument, "The relay sent an invalid lease update.")
        }
        var next = state
        for (id, saved) in state.requests {
            let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
            guard record.leaseID == lease.leaseID else { continue }
            guard record.loginID == lease.loginID, record.recipientID == lease.recipient.recipientID,
                  record.taskRef == lease.taskRef, record.purpose == lease.purpose,
                  record.reason == lease.reason, record.program == lease.program else {
                throw RelayFailure(.permissionDenied, "A lease update changed the saved request's scope.")
            }
            next.requests[id]!.lease = try lease.serializedData()
        }
        next.remoteLeases[lease.leaseID] = try lease.serializedData()
        try commit(next)
    }

    public func endAccess(_ id: String) async throws -> AccessRequestState {
        let leaseID: String
        if let saved = state.requests[id] { leaseID = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record).leaseID }
        else if id.hasPrefix("lease:"), state.remoteLeases[String(id.dropFirst(6))] != nil { leaseID = String(id.dropFirst(6)) }
        else { throw RelayFailure(.notFound, "No such request.") }
        var command = Agentkeyring_V1_RelayWireRequest(); command.revokeLease.leaseID = leaseID
        let response = try await transport().call(command)
        guard case let .lease(lease) = response.response, lease.leaseID == leaseID,
              [.revoked, .expired, .released, .denied, .cancelled, .unanswered].contains(lease.state) else {
            throw RelayFailure(.unavailable, "The relay has not confirmed that access ended.")
        }
        try receiveLease(lease)
        return state.requests[id] != nil ? try requestState(id) : screenState(lease, verifiedReply: nil)
    }
}
