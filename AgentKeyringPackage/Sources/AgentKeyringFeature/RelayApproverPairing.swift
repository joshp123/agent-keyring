import AgentKeyringProtocol
import CryptoKit
import Foundation
import LocalAuthentication

extension RelayApprover {
    public func beginPairing(_ endpoint: RelayEndpoint) async throws {
        try load()
        guard state.keySet == nil else { throw LeaseFailure(.conflict, "This Mac is already paired with a relay.") }
        if state.pairing?.confirmation != nil { start(); return }
        let (identity, signer) = try keys()
        var key = Agentkeyring_V1_ApproverKey()
        key.keyID = RelayCrypto.keyID(signer.publicKey)
        key.publicKey = signer.publicKey
        key.label = Host.current().localizedName ?? "This Mac"
        key.tlsPublicKey = identity.publicKeySPKI
        key.role = .mac
        var request = Agentkeyring_V1_RelayWireRequest()
        request.pairApprover.key = key
        request.pairApprover.tlsPublicKey = identity.publicKeySPKI
        pairConnection?.cancel()
        pairingAttemptID = UUID()
        let connection = RelayConnection(endpoint: endpoint, identity: identity, pin: nil)
        pairConnection = connection
        do {
            try await connection.open()
            try await connection.send(request)
            let response = try await connection.next()
            guard pairConnection === connection else { throw CancellationError() }
            guard case let .enrolStatus(status) = response.response, status.state == .pending,
                status.approverKeySet.keySet.isEmpty, status.approverKeys.isEmpty else {
                throw LeaseFailure(.permissionDenied, "The relay already has an approver. This first-setup flow cannot replace it.")
            }
            let pin = connection.peerSPKI
            guard !pin.isEmpty else { throw LeaseFailure(.unauthenticated, "The relay did not present a TLS identity.") }
            let transcript = RelayCrypto.pairTranscript(relaySPKI: pin, approverSPKI: identity.publicKeySPKI,
                signingKey: signer.publicKey, keySet: Data())
            var next = state
            next.pairing = RelayPendingPair(endpoint: endpoint, relaySPKI: pin, transcript: transcript)
            try commit(next)
        } catch {
            connection.cancel()
            if pairConnection === connection { pairConnection = nil }
            throw error
        }
    }

    public func abandonPairing() throws {
        try load()
        guard state.keySet == nil, state.pairing?.confirmation == nil else {
            throw LeaseFailure(.conflict, "Relay pairing has already been confirmed.")
        }
        var next = state
        next.pairing = nil
        try commit(next)
        pairingAttemptID = UUID()
        pairConnection?.cancel()
        pairConnection = nil
        connectionState = .notPaired
        errorMessage = nil
        publish()
    }

    public func confirmPairing(comparedFingerprint: String, context: LAContext = LAContext()) async throws {
        try load()
        guard let pending = state.pairing else { throw LeaseFailure(.notFound, "There is no pairing to confirm.") }
        guard comparedFingerprint == RelayCrypto.fingerprint(pending.transcript) else {
            throw LeaseFailure(.invalidArgument, "Compare every group of the fingerprint on the relay and this Mac.")
        }
        if pending.confirmation != nil { start(); await flushOutbox(); return }
        let attemptID = pairingAttemptID
        try claimAuthorization("pairing")
        defer { authorizationID = nil }
        let (identity, signer) = try keys()
        try await signer.authorize(context: context, reason: "Pair Agent Keyring with the relay after comparing the full fingerprint")
        try Task.checkCancellation()
        guard pairingAttemptID == attemptID, state.pairing?.transcript == pending.transcript, state.keySet == nil else {
            throw LeaseFailure(.conflict, "Pairing changed. Compare the current fingerprint.")
        }
        var key = Agentkeyring_V1_ApproverKey()
        key.keyID = RelayCrypto.keyID(signer.publicKey)
        key.publicKey = signer.publicKey
        key.label = Host.current().localizedName ?? "This Mac"
        key.tlsPublicKey = identity.publicKeySPKI
        key.role = .mac
        var keySet = Agentkeyring_V1_ApproverKeySet()
        keySet.domain = "agentkeyring.approvers.v1"
        keySet.revision = 1
        keySet.keys = [key]
        keySet.ruleOwnerKeyID = key.keyID
        keySet.pairingTranscriptSha256 = RelayCrypto.hash(pending.transcript)
        let keySetBytes = try keySet.serializedData()
        var confirmation = Agentkeyring_V1_PairingConfirmation()
        confirmation.domain = "agentkeyring.pairconfirm.v1"
        confirmation.transcriptSha256 = keySet.pairingTranscriptSha256
        confirmation.confirmedUnixSeconds = Self.now
        let bytes = try confirmation.serializedData()
        var wire = Agentkeyring_V1_RelayWireRequest()
        wire.confirmPairing.confirmation = bytes
        wire.confirmPairing.signature = try signer.sign(bytes, context: context, automatic: false)
        wire.confirmPairing.approverKeyID = key.keyID
        wire.confirmPairing.initialKeySet.keySet = keySetBytes
        wire.confirmPairing.initialKeySet.signature = try signer.sign(keySetBytes, context: context, automatic: false)
        wire.confirmPairing.initialKeySet.signerKeyID = key.keyID
        var next = state
        next.pairing!.confirmation = try wire.serializedData()
        try enqueue(wire, id: "pairing", into: &next)
        try commit(next)
        start()
        await flushOutbox()
    }

    public func approveEnrolment(_ id: String, comparedFingerprint: String, automaticAllowed: Bool = false,
        context: LAContext = LAContext()) async throws {
        try load()
        guard let bytes = state.pendingEnrolments[id] else {
            throw LeaseFailure(.notFound, "No such machine is waiting to enrol.")
        }
        let record = try validateEnrolment(bytes)
        let current = try currentKeySet()
        let transcript = RelayCrypto.enrolTranscript(relaySPKI: state.relaySPKI!, clientSPKI: record.tlsPublicKey,
            receiverKey: record.receiverPublicKey, keySet: current.keySet)
        guard comparedFingerprint == RelayCrypto.fingerprint(transcript) else {
            throw LeaseFailure(.invalidArgument, "Compare every fingerprint group with the new machine.")
        }
        try claimAuthorization("enrolment:" + id)
        defer { authorizationID = nil }
        let signer = try keys().1
        try await signer.authorize(context: context, reason: "Allow \(record.machineLabel) to request logins after comparing its full fingerprint")
        try Task.checkCancellation()
        let vault = try await credentialSource()
        try Task.checkCancellation()
        guard try currentKeySet() == current, state.pendingEnrolments[id] == bytes else {
            throw LeaseFailure(.conflict, "The machine comparison changed. Compare the current fingerprint.")
        }
        var machine = Agentkeyring_V1_EnrolledMachine()
        machine.recipientID = record.recipientID
        machine.machineLabel = record.machineLabel
        machine.clientLabel = record.clientLabel
        machine.tailscaleNodeID = record.tailscaleNodeID
        machine.tlsPublicKey = record.tlsPublicKey
        machine.receiverPublicKey = record.receiverPublicKey
        machine.receiverKeyID = record.receiverKeyID
        machine.automaticAllowed = automaticAllowed
        var next = state
        next.pendingEnrolments.removeValue(forKey: id)
        next.machines[record.recipientID] = try machine.serializedData()
        try preparePublication(next: &next, vault: vault, context: context)
        try commit(next, vault: vault)
        needsPublication = false
        publish()
        await flushOutbox()
    }

    func validateEnrolment(_ bytes: Data) throws -> Agentkeyring_V1_EnrolmentRecord {
        let record = try Agentkeyring_V1_EnrolmentRecord(serializedBytes: bytes)
        let current = try currentKeySet()
        guard !record.recipientID.isEmpty, !record.machineLabel.isEmpty, !record.tailscaleNodeID.isEmpty,
            !record.tlsPublicKey.isEmpty,
            record.approverKeySetSha256 == RelayCrypto.hash(current.keySet),
            record.receiverKeyID == RelayCrypto.keyID(record.receiverPublicKey) else {
            throw LeaseFailure(.invalidArgument, "The machine keys or compared approver set are invalid.")
        }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: record.receiverPublicKey)
        if let enrolled = state.machines[record.recipientID] {
            let machine = try Agentkeyring_V1_EnrolledMachine(serializedBytes: enrolled)
            guard machine.tlsPublicKey == record.tlsPublicKey, machine.receiverPublicKey == record.receiverPublicKey else {
                throw LeaseFailure(.conflict, "The enrolled machine's keys changed.")
            }
        }
        return record
    }
}

extension RelayApprover {
    public func denyEnrolment(_ id: String, context: LAContext = LAContext()) async throws {
        try load()
        guard let bytes = state.pendingEnrolments[id] else { throw LeaseFailure(.notFound, "No such machine is waiting to enrol.") }
        let record = try validateEnrolment(bytes)
        var command = Agentkeyring_V1_RelayWireRequest()
        command.dismissEnrolment.recipientID = record.recipientID
        var next = state
        next.pendingEnrolments.removeValue(forKey: id)
        try enqueue(command, id: "enrolment:" + id, into: &next)
        try commit(next)
        await flushOutbox()
    }

    public func revokeMachine(_ recipientID: String, context: LAContext = LAContext()) async throws {
        try load()
        guard let machineBytes = state.machines[recipientID] else { return }
        let machine = try Agentkeyring_V1_EnrolledMachine(serializedBytes: machineBytes)
        try claimAuthorization("revoke:" + recipientID)
        defer { authorizationID = nil }
        try await keys().1.authorize(context: context, reason: "End Agent Keyring access for \(machine.machineLabel)")
        let vault = try await credentialSource()
        try Task.checkCancellation()
        guard state.machines[recipientID] == machineBytes else { throw LeaseFailure(.conflict, "This machine's enrolment changed.") }
        var next = state
        next.machines.removeValue(forKey: recipientID)
        for (id, saved) in next.requests {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            if lease.recipient.recipientID == recipientID && (lease.state == .pending || lease.state == .active) {
                lease.state = .revoked
                lease.endedAtUnixSeconds = Self.now
                next.requests[id]!.lease = try lease.serializedData()
                next.outbox.removeAll { $0.id == "decision:" + id }
            }
        }
        try preparePublication(next: &next, vault: vault, context: context)
        try commit(next, vault: vault)
        needsPublication = false
        publish()
        await flushOutbox()
    }
}
