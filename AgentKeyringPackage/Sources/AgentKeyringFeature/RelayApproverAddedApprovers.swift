import AgentKeyringProtocol
import CryptoKit
import Foundation
import LocalAuthentication

public struct RelayApproverPairing: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let fingerprint: String
    public let answerIsQueued: Bool
    public let replacesPhoneKeyID: String?
    public let replacesPhoneLabel: String?
}

extension RelayApprover {
    func phoneBeingReplaced(by request: Agentkeyring_V1_PairApproverRequest,
        in keySet: Agentkeyring_V1_ApproverKeySet) -> Agentkeyring_V1_ApproverKey? {
        keySet.keys.first { $0.role == .phone && $0.keyID != request.key.keyID && $0.tlsPublicKey == request.tlsPublicKey }
    }

    func receiveApproverPairing(_ request: Agentkeyring_V1_PairApproverRequest) throws {
        guard state.dismissedApproverPairingIDs?.contains(request.key.keyID) != true else { return }
        let current = try Agentkeyring_V1_ApproverKeySet(serializedBytes: currentKeySet().keySet)
        guard !request.key.keyID.isEmpty, !request.key.label.isEmpty,
            request.tlsPublicKey == request.key.tlsPublicKey else {
            throw LeaseFailure(.invalidArgument, "The new approver's signing and TLS keys are incomplete.")
        }
        guard request.key.role == .phone, request.key.keyID == RelayCrypto.keyID(request.key.publicKey) else {
            throw LeaseFailure(.permissionDenied, "Only an explicitly identified phone may join as an approver.")
        }
        _ = try P256.Signing.PublicKey(x963Representation: request.key.publicKey)
        _ = try P256.Signing.PublicKey(derRepresentation: request.tlsPublicKey)
        if !request.key.encryptionPublicKey.isEmpty {
            guard request.key.encryptionPublicKey.count == 65 else {
                throw LeaseFailure(.invalidArgument, "The phone's login-copy key must be a P-256 X9.63 public key.")
            }
            _ = try P256.KeyAgreement.PublicKey(x963Representation: request.key.encryptionPublicKey)
        }
        if let existing = current.keys.first(where: { $0.keyID == request.key.keyID }) {
            guard existing == request.key else { throw LeaseFailure(.conflict, "An existing approver's keys changed.") }
            return
        }
        let bytes = try request.serializedData()
        if state.pendingApprovers?[request.key.keyID] == bytes { return }
        var next = state
        if next.pendingApprovers == nil { next.pendingApprovers = [:] }
        next.pendingApprovers![request.key.keyID] = bytes
        if next.pendingApproverCreated == nil { next.pendingApproverCreated = [:] }
        next.pendingApproverCreated![request.key.keyID] = Self.now
        try commit(next)
    }

    public func dismissApproverPairing(_ id: String) throws {
        try load()
        if state.dismissedApproverPairingIDs?.contains(id) == true { return }
        guard state.pendingApprovers?[id] != nil else { throw LeaseFailure(.notFound, "No approver is waiting for that comparison.") }
        guard !state.outbox.contains(where: { $0.id == "approver-pairing:" + id }) else {
            throw LeaseFailure(.conflict, "This approver pairing has already been confirmed.")
        }
        var next = state
        if next.dismissedApproverPairingIDs == nil { next.dismissedApproverPairingIDs = [] }
        next.dismissedApproverPairingIDs!.insert(id)
        next.pendingApprovers?.removeValue(forKey: id)
        try commit(next)
    }

    public func confirmApproverPairing(_ id: String, comparedFingerprint: String,
        context: LAContext = LAContext()) async throws {
        try load()
        let queuedID = "approver-pairing:" + id
        if state.outbox.contains(where: { $0.id == queuedID }) { await flushOutbox(); return }
        guard !state.outbox.contains(where: { $0.id.hasPrefix("approver-pairing:") }) else {
            throw LeaseFailure(.conflict, "Finish delivering the previous approver pairing before adding another device.")
        }
        let previous = try currentKeySet()
        let previousSet = try Agentkeyring_V1_ApproverKeySet(serializedBytes: previous.keySet)
        guard let bytes = state.pendingApprovers?[id] else {
            if previousSet.keys.contains(where: { $0.keyID == id }) { return }
            throw LeaseFailure(.notFound, "No approver is waiting for that comparison.")
        }
        guard let configurationBytes = state.configuration else {
            throw LeaseFailure(.unavailable, "Publish your current rules and machines before pairing another approver.")
        }
        let request = try Agentkeyring_V1_PairApproverRequest(serializedBytes: bytes)
        let replaced = phoneBeingReplaced(by: request, in: previousSet)
        let transcript = RelayCrypto.pairTranscript(relaySPKI: state.relaySPKI!, approverSPKI: request.tlsPublicKey,
            signingKey: request.key.publicKey, keySet: previous.keySet, encryptionKey: request.key.encryptionPublicKey)
        guard comparedFingerprint == RelayCrypto.fingerprint(transcript) else {
            throw LeaseFailure(.invalidArgument, "Compare every fingerprint group with the new approving device.")
        }
        try claimAuthorization(queuedID)
        defer { authorizationID = nil }
        let signer = try keys().1
        let reason = replaced.map { "Replace the Agent Keyring approval keys for \($0.label) after comparing the full fingerprint" }
            ?? "Allow \(request.key.label) to approve Agent Keyring requests after comparing its full fingerprint"
        try await signer.authorize(context: context, reason: reason)
        let vault = request.key.encryptionPublicKey.isEmpty ? nil : try await credentialSource()
        try Task.checkCancellation()
        guard try currentKeySet() == previous, state.configuration == configurationBytes, state.pendingApprovers?[id] == bytes else {
            throw LeaseFailure(.conflict, "The approver or machine list changed. Compare the current fingerprint.")
        }
        let signedConfiguration = try Agentkeyring_V1_SignedConfiguration(serializedBytes: configurationBytes)
        let configuration = try Agentkeyring_V1_Configuration(serializedBytes: signedConfiguration.configuration)
        var nextSet = previousSet
        nextSet.revision += 1
        if let replaced { nextSet.keys.removeAll { $0.keyID == replaced.keyID } }
        nextSet.keys.append(request.key)
        nextSet.configurationRevision = configuration.revision
        nextSet.configurationSha256 = RelayCrypto.hash(signedConfiguration.configuration)
        nextSet.pairingTranscriptSha256 = RelayCrypto.hash(transcript)
        var signed = Agentkeyring_V1_SignedApproverKeySet()
        signed.keySet = try nextSet.serializedData()
        signed.signature = try signer.sign(signed.keySet, context: context, automatic: false)
        signed.signerKeyID = RelayCrypto.keyID(signer.publicKey)
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishApproverKeys = signed
        var next = state
        if let replaced, !replaced.encryptionPublicKey.isEmpty,
            replaced.encryptionPublicKey != request.key.encryptionPublicKey {
            let prefix = "login-copy:\(RelayCrypto.keyID(replaced.encryptionPublicKey)):"
            next.outbox.removeAll { $0.id.hasPrefix(prefix) }
        }
        try enqueue(command, id: queuedID, into: &next)
        if let vault, try !requiresPublicationConfirmation(vault) {
            try prepareLoginCopy(next: &next, vault: vault, configuration: configuration,
                receiverKey: request.key.encryptionPublicKey, rule: .ask, policy: .ask)
        }
        try commit(next)
        await flushOutbox()
    }
}
