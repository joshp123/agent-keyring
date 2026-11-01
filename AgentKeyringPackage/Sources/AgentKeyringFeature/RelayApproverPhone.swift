import AgentKeyringRelaySupport
import AgentKeyringProtocol
import Foundation

extension RelayApprover {
    func receivePhoneDecision(_ signed: Agentkeyring_V1_SignedPhoneDecision) async throws {
        let decision = try Agentkeyring_V1_PhoneDecision(serializedBytes: signed.decision)
        let id = RelayCrypto.hex(decision.requestDigest)
        let local = leaseStore.localPhoneRequest(decision.leaseID)
        let recordBytes: Data
        if let local { recordBytes = local.record }
        else if let request = state.requests[id] { recordBytes = request.record }
        else { throw LeaseFailure(.notFound, "The phone answer has no matching request on this Mac.") }
        let record = try Agentkeyring_V1_RequestRecord(serializedBytes: recordBytes)
        let set = try Agentkeyring_V1_ApproverKeySet(serializedBytes: currentKeySet().keySet)
        guard let key = set.keys.first(where: { $0.keyID == signed.phoneKeyID && $0.role == .phone }),
            decision.domain == "agentkeyring.phonedecision.v1",
            decision.requestDigest == RelayCrypto.digest("agentkeyring.request.v1", recordBytes),
            decision.leaseID == record.leaseID,
            [.approve, .deny].contains(decision.choice),
            decision.replySha256 == RelayCrypto.hash(Data(signed.reply.utf8)),
            decision.decidedUnixSeconds >= record.createdUnixSeconds,
            decision.decidedUnixSeconds < record.pendingUntilUnixSeconds,
            decision.decidedUnixSeconds <= Self.now + 60 else {
            throw LeaseFailure(.permissionDenied, "The phone answer does not match the retained request or a paired phone.")
        }
        let plainDenial = decision.choice == .deny && signed.reply.isEmpty && signed.signature.isEmpty
        if !plainDenial {
            guard try RelayCrypto.verify(signature: signed.signature, statement: signed.decision, publicKey: key.publicKey) else {
                throw LeaseFailure(.permissionDenied, "The phone signature could not be checked.")
            }
        }
        if decision.choice == .approve {
            guard signed.reply.isEmpty, decision.notAfterUnixSeconds > Self.now,
                decision.notAfterUnixSeconds > decision.decidedUnixSeconds,
                decision.notAfterUnixSeconds <= decision.decidedUnixSeconds + 1800 else {
                throw LeaseFailure(.permissionDenied, "The phone approval has expired or exceeds 30 minutes.")
            }
        } else if decision.notAfterUnixSeconds != 0 { throw LeaseFailure(.invalidArgument, "A denial has no delivery deadline.") }
        let vault: RelayApproverVault?
        if decision.choice == .approve {
            let current = try await credentialSource()
            guard let item = current.generation.items.first(where: { $0.id == UUID(uuidString: record.loginID) }),
                current.policies[item.id, default: .ask] != .block else {
                throw LeaseFailure(.permissionDenied, "This login is no longer available for approval.")
            }
            vault = current
        } else { vault = nil }
        try Task.checkCancellation()
        let latestKeys = try Agentkeyring_V1_ApproverKeySet(serializedBytes: currentKeySet().keySet)
        guard latestKeys.keys.contains(key) else { throw LeaseFailure(.permissionDenied, "This phone is no longer paired.") }
        if let local {
            guard local.escalated else { throw LeaseFailure(.permissionDenied, "This local request was never sent to the phone.") }
            _ = try leaseStore.answerFromPhone(decision, phoneKeyID: signed.phoneKeyID, reply: signed.reply)
        } else {
            guard state.requests[id]?.escalated == true else { throw LeaseFailure(.permissionDenied, "This request was never sent to the phone.") }
            if state.requests[id]?.decision == nil {
                try queueDecision(id, approve: decision.choice == .approve, reply: signed.reply,
                    automatic: false, context: nil, vault: vault, suppress: decision.choice == .deny, phone: signed)
            }
        }
        await flushOutbox()
    }

    func receiveLocalLeaseAction(_ action: Agentkeyring_V1_LocalLeaseAction) throws {
        switch action.action {
        case let .revokeLease(reference):
            guard leaseStore.localPhoneRequest(reference.leaseID)?.escalated == true else {
                throw LeaseFailure(.permissionDenied, "That lease was not sent to the phone.")
            }
            try leaseStore.revoke(reference.leaseID)
            try leaseStore.reportPhoneLease(reference.leaseID)
        case let .clearDenial_p(request):
            guard try leaseStore.recipient().recipientID == request.recipientID else {
                throw LeaseFailure(.permissionDenied, "That denial belongs to another recipient.")
            }
            try leaseStore.clearDenial(loginID: request.loginID)
            for lease in leaseStore.leases where lease.loginID == request.loginID && lease.state == .denied {
                try leaseStore.reportPhoneLease(lease.leaseID)
            }
        case nil: throw LeaseFailure(.invalidArgument, "The phone sent an empty local action.")
        }
    }
}
