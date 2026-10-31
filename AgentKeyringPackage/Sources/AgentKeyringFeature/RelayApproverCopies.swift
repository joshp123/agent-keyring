import AgentKeyringProtocol
import CryptoKit
import Foundation

extension RelayApprover {
    func validateAutomaticKeys(_ keys: Agentkeyring_V1_AutomaticKeys) throws {
        _ = try P256.Signing.PublicKey(x963Representation: keys.signingPublicKey)
        _ = try P256.KeyAgreement.PublicKey(x963Representation: keys.encryptionPublicKey)
        guard keys.signingKeyID == RelayCrypto.keyID(keys.signingPublicKey),
            keys.encryptionKeyID == RelayCrypto.keyID(keys.encryptionPublicKey) else {
            throw LeaseFailure(.unauthenticated, "The relay's Automatic keys do not match their identifiers.")
        }
    }

    func automaticKeys(in next: RelayApproverState) throws -> Agentkeyring_V1_AutomaticKeys {
        guard let bytes = next.automaticKeys else {
            throw LeaseFailure(.unavailable, "The relay's Automatic keys have not arrived yet.")
        }
        let keys = try Agentkeyring_V1_AutomaticKeys(serializedBytes: bytes)
        try validateAutomaticKeys(keys)
        return keys
    }

    func prepareForPublication() async throws {
        try load()
        guard state.keySet != nil, state.automaticKeys == nil else { return }
        let keys = try await fetchAutomaticKeys(using: transport())
        var next = state
        next.automaticKeys = try keys.serializedData()
        try commit(next)
    }

    func fetchAutomaticKeys(using client: RelayTransport) async throws -> Agentkeyring_V1_AutomaticKeys {
        var command = Agentkeyring_V1_RelayWireRequest()
        command.getAutomaticKeys = Agentkeyring_V1_GetAutomaticKeysRequest()
        let response = try await client.call(command)
        guard case let .automaticKeys(keys) = response.response else {
            throw LeaseFailure(.unavailable, "The relay did not return its Automatic keys.")
        }
        try validateAutomaticKeys(keys)
        return keys
    }

    func prepareLoginCopies(next: inout RelayApproverState, vault: RelayApproverVault,
        configuration: Agentkeyring_V1_Configuration) throws {
        let keys = try automaticKeys(in: next)
        if configuration.automaticSigningPublicKey == keys.signingPublicKey,
            configuration.automaticKeyID == keys.signingKeyID,
            configuration.relayEncryptionPublicKey == keys.encryptionPublicKey {
            try prepareLoginCopy(next: &next, vault: vault, configuration: configuration,
                receiverKey: keys.encryptionPublicKey, rule: .automatic, policy: .allowAutomatically)
        }
        guard let bytes = next.keySet else { throw LeaseFailure(.permissionDenied, "This Mac is not paired.") }
        let keySet = try Agentkeyring_V1_ApproverKeySet(serializedBytes:
            Agentkeyring_V1_SignedApproverKeySet(serializedBytes: bytes).keySet)
        for phone in keySet.keys.filter({ $0.role == .phone && !$0.encryptionPublicKey.isEmpty }).sorted(by: { $0.keyID < $1.keyID }) {
            try prepareLoginCopy(next: &next, vault: vault, configuration: configuration,
                receiverKey: phone.encryptionPublicKey, rule: .ask, policy: .ask)
        }
    }

    func prepareLoginCopy(next: inout RelayApproverState, vault: RelayApproverVault,
        configuration: Agentkeyring_V1_Configuration, receiverKey: Data,
        rule: Agentkeyring_V1_AccessRule, policy: CredentialAccessPolicy) throws {
        let destination = RelayCrypto.keyID(receiverKey)
        let previous = next.loginCopies?[destination]
        guard previous?.configurationRevision != configuration.revision || previous?.generationID != vault.generation.id else { return }
        let signer = try self.keys().1
        guard let keySetBytes = next.keySet else { throw LeaseFailure(.permissionDenied, "This Mac is not paired.") }
        let keySet = try Agentkeyring_V1_ApproverKeySet(serializedBytes:
            Agentkeyring_V1_SignedApproverKeySet(serializedBytes: keySetBytes).keySet)
        let signerID = RelayCrypto.keyID(signer.automaticPublicKey)
        guard keySet.keys.contains(where: { $0.keyID == signerID && $0.role == .macDelivery }) else {
            throw LeaseFailure(.permissionDenied, "Confirm your rules to allow background login copies.")
        }
        var update = Agentkeyring_V1_CopyUpdate()
        update.domain = "agentkeyring.copy-update.v1"
        update.destinationKeyID = destination
        update.configurationRevision = configuration.revision
        update.revision = (previous?.revision ?? 0) + 1
        for login in configuration.logins.filter({ $0.rule == rule }).sorted(by: { $0.loginID < $1.loginID }) {
            guard let item = vault.generation.items.first(where: { $0.id.uuidString == login.loginID }),
                vault.policies[item.id, default: .ask] == policy else {
                throw LeaseFailure(.conflict, "A login's rule changed before its copy could be saved.")
            }
            let contents = try RelayCrypto.loginCopyContents(item: item)
            update.logins.append(try RelayCrypto.sealLoginCopy(contents, receiverKey: receiverKey,
                configurationRevision: update.configurationRevision, revision: update.revision))
        }
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishCopyUpdate.update = try update.serializedData()
        command.publishCopyUpdate.signature = try signer.sign(command.publishCopyUpdate.update, context: nil, automatic: true)
        command.publishCopyUpdate.signerKeyID = signerID
        try enqueue(command, id: "login-copy:\(destination):\(update.revision)", into: &next)
        if next.loginCopies == nil { next.loginCopies = [:] }
        next.loginCopies![destination] = RelaySavedCopy(revision: update.revision,
            configurationRevision: configuration.revision, generationID: vault.generation.id)
    }
}
