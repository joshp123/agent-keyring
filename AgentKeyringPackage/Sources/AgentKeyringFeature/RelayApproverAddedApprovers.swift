import AgentKeyringProtocol
import CryptoKit
import Foundation
import LocalAuthentication

public struct RelayApproverPairing: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let fingerprint: String
    public let answerIsQueued: Bool
}

extension RelayApprover {
    func receiveApproverPairing(_ request: Agentkeyring_V1_PairApproverRequest) throws {
        let current = try Agentkeyring_V1_ApproverKeySet(serializedBytes: currentKeySet().keySet)
        guard !request.key.keyID.isEmpty, !request.key.label.isEmpty,
            request.tlsPublicKey == request.key.tlsPublicKey else {
            throw LeaseFailure(.invalidArgument, "The new approver's signing and TLS keys are incomplete.")
        }
        _ = try P256.Signing.PublicKey(x963Representation: request.key.publicKey)
        _ = try P256.Signing.PublicKey(derRepresentation: request.tlsPublicKey)
        if let existing = current.keys.first(where: { $0.keyID == request.key.keyID }) {
            guard existing == request.key else { throw LeaseFailure(.conflict, "An existing approver's keys changed.") }
            return
        }
        let bytes = try request.serializedData()
        if state.pendingApprovers?[request.key.keyID] == bytes { return }
        var next = state
        if next.pendingApprovers == nil { next.pendingApprovers = [:] }
        next.pendingApprovers![request.key.keyID] = bytes
        try commit(next)
    }

    public func confirmApproverPairing(_ id: String, comparedFingerprint: String,
        context: LAContext = LAContext()) async throws {
        try load()
        let queuedID = "approver-pairing:" + id
        if state.outbox.contains(where: { $0.id == queuedID }) { await flushOutbox(); return }
        let previous = try currentKeySet()
        let previousSet = try Agentkeyring_V1_ApproverKeySet(serializedBytes: previous.keySet)
        guard let bytes = state.pendingApprovers?[id] else {
            if previousSet.keys.contains(where: { $0.keyID == id }) { return }
            throw LeaseFailure(.notFound, "No approver is waiting for that comparison.")
        }
        guard let rosterBytes = state.enrolmentSet else {
            throw LeaseFailure(.unavailable, "Publish your current rules and machines before pairing another approver.")
        }
        let request = try Agentkeyring_V1_PairApproverRequest(serializedBytes: bytes)
        let transcript = RelayCrypto.pairTranscript(relaySPKI: state.relaySPKI!, approverSPKI: request.tlsPublicKey,
            signingKey: request.key.publicKey, keySet: previous.keySet)
        guard comparedFingerprint == RelayCrypto.fingerprint(transcript) else {
            throw LeaseFailure(.invalidArgument, "Compare every fingerprint group with the new approving device.")
        }
        try claimAuthorization(queuedID)
        defer { authorizationID = nil }
        let signer = try keys().1
        try await signer.authorize(context: context, reason: "Allow \(request.key.label) to approve Agent Keyring requests after comparing its full fingerprint")
        try Task.checkCancellation()
        guard try currentKeySet() == previous, state.enrolmentSet == rosterBytes, state.pendingApprovers?[id] == bytes else {
            throw LeaseFailure(.conflict, "The approver or machine list changed. Compare the current fingerprint.")
        }
        let roster = try Agentkeyring_V1_SignedEnrolmentSet(serializedBytes: rosterBytes)
        let rosterContents = try Agentkeyring_V1_EnrolmentSet(serializedBytes: roster.enrolmentSet)
        var nextSet = previousSet
        nextSet.revision += 1
        nextSet.keys.append(request.key)
        nextSet.enrolmentSetRevision = rosterContents.revision
        nextSet.enrolmentSetSha256 = RelayCrypto.hash(roster.enrolmentSet)
        nextSet.pairingTranscriptSha256 = RelayCrypto.hash(transcript)
        var signed = Agentkeyring_V1_SignedApproverKeySet()
        signed.keySet = try nextSet.serializedData()
        signed.signature = try signer.sign(signed.keySet, context: context, automatic: false)
        signed.signerKeyID = RelayCrypto.keyID(signer.publicKey)
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishApproverKeys = signed
        var next = state
        try enqueue(command, id: queuedID, into: &next)
        try commit(next)
        await flushOutbox()
    }
}
