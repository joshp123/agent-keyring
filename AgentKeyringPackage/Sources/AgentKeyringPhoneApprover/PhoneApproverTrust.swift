import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import CryptoKit
import Foundation

extension PhoneRelayApprover {
    func parsedKeys(_ signed: Agentkeyring_V1_SignedApproverKeySet) throws -> Agentkeyring_V1_ApproverKeySet {
        let set = try Agentkeyring_V1_ApproverKeySet(serializedBytes: signed.keySet)
        guard set.domain == "agentkeyring.approvers.v1", set.revision > 0,
              !set.keys.isEmpty, Set(set.keys.map(\.keyID)).count == set.keys.count,
              set.keys.contains(where: { $0.keyID == set.ruleOwnerKeyID && ($0.role == .mac || $0.role == .unspecified) }) else {
            throw RelayFailure(.permissionDenied, "The approver key set is invalid.")
        }
        for key in set.keys {
            guard key.keyID == RelayCrypto.keyID(key.publicKey),
                  (key.role == .macDelivery ? key.tlsPublicKey.isEmpty : !key.tlsPublicKey.isEmpty),
                  [.mac, .phone, .macDelivery].contains(key.role) || (key.role == .unspecified && key.keyID == set.ruleOwnerKeyID) else {
                throw RelayFailure(.permissionDenied, "The approver identity is invalid.")
            }
            _ = try P256.Signing.PublicKey(x963Representation: key.publicKey)
            if !key.encryptionPublicKey.isEmpty {
                guard key.role == .phone else { throw RelayFailure(.permissionDenied, "Only a phone may have a copy key.") }
                _ = try P256.KeyAgreement.PublicKey(x963Representation: key.encryptionPublicKey)
            }
        }
        return set
    }

    func currentKeys() throws -> Agentkeyring_V1_SignedApproverKeySet {
        guard let bytes = state.keySet else { throw RelayFailure(.permissionDenied, "This iPhone is not paired.") }
        return try Agentkeyring_V1_SignedApproverKeySet(serializedBytes: bytes)
    }

    func verify(_ signature: Data, bytes: Data, signerID: String, in set: Agentkeyring_V1_ApproverKeySet) throws {
        guard let key = set.keys.first(where: { $0.keyID == signerID }),
              key.role == .mac || (key.role == .unspecified && key.keyID == set.ruleOwnerKeyID),
              try RelayCrypto.verify(signature: signature, statement: bytes, publicKey: key.publicKey) else {
            throw RelayFailure(.permissionDenied, "The signed record does not match the trusted approvers.")
        }
    }

    public func beginReplacementPairing() async throws {
        try load()
        guard state.keySet != nil, let endpoint = state.endpoint else {
            throw RelayFailure(.conflict, "This iPhone is not paired.")
        }
        guard !authorizing, !flushing else {
            throw RelayFailure(.conflict, "An answer is still being sent. Try pairing again when it finishes.")
        }
        let previousKeyID: String
        if let removed = state.removedKeyID { previousKeyID = removed }
        else {
            let previousSet = try parsedKeys(currentKeys())
            let tlsKey = try identityProvider().publicKeySPKI
            guard let previousPhone = previousSet.keys.first(where: { $0.role == .phone && $0.tlsPublicKey == tlsKey }) else {
                throw RelayFailure(.permissionDenied, "The saved pairing does not identify this iPhone.")
            }
            previousKeyID = previousPhone.keyID
        }
        stop()
        var next = PhoneApproverState()
        next.endpoint = endpoint; next.relaySPKI = state.relaySPKI
        next.replacementPairing = PhoneReplacementPairing(previousKeyID: previousKeyID, needsFreshIdentity: true)
        try commit(next)
        pairing = .notPaired; connection = .notPaired; lastFailure = nil; publish()
        try await beginPairing(endpoint: endpoint)
    }

    public func beginPairing(endpoint requestedEndpoint: RelayEndpoint) async throws {
        try load()
        if state.removedKeyID != nil {
            try await beginReplacementPairing()
            return
        }
        guard state.keySet == nil else { throw RelayFailure(.conflict, "This iPhone is already paired.") }
        let endpoint: RelayEndpoint
        if state.replacementPairing != nil {
            guard let savedEndpoint = state.endpoint else {
                throw RelayFailure(.conflict, "The relay for this iPhone's replacement is unavailable.")
            }
            endpoint = savedEndpoint
        } else {
            endpoint = requestedEndpoint
        }
        if state.replacementPairing?.needsFreshIdentity == true {
            // The unpaired receipt is durable before removing any key. An interrupted
            // reset can retry; it can never reopen the retired copy or its outbox.
            try replaceIdentity()
            var next = state; next.replacementPairing?.needsFreshIdentity = false
            try commit(next)
        }
        pairingAttempt = UUID()
        pairTask?.cancel(); pairTask = nil; pairConnection?.cancel(); pairConnection = nil
        var requested = state; requested.pairingWanted = true; try commit(requested)
        let savedComparison = state.pendingPair
        let attempt = pairingAttempt
        logger.notice("Starting phone approver pairing")
        pairing = .connecting; publish()
        defer {
            if pairingAttempt == attempt, pairing == .connecting {
                pairing = .failed("Pairing could not start. Check the relay and Tailscale."); publish()
            }
        }
        var request = Agentkeyring_V1_RelayWireRequest()
        let identity = try identityProvider()
        let publicKey = try keys.signingPublicKey()
        request.pairApprover.key.keyID = RelayCrypto.keyID(publicKey)
        request.pairApprover.key.publicKey = publicKey
        request.pairApprover.key.tlsPublicKey = identity.publicKeySPKI
        request.pairApprover.key.label = "Josh's iPhone"
        request.pairApprover.key.role = .phone
        request.pairApprover.key.encryptionPublicKey = try keys.encryptionPublicKey()
        request.pairApprover.tlsPublicKey = identity.publicKeySPKI
        let pin = endpoint == state.endpoint ? state.relaySPKI : nil
        let connection = try await RelayTransport(endpoint: endpoint, identity: identity, pin: pin).open(request)
        do {
            let response = try await connection.next()
            guard pairingAttempt == attempt else { throw CancellationError() }
            guard case let .enrolStatus(status) = response.response else {
                throw RelayFailure(.permissionDenied, "Start pairing from an existing Mac approver. This iPhone cannot create the first authority.")
            }
            if status.state == .approved, let pending = savedComparison,
               pending.endpoint == endpoint, pending.relaySPKI == connection.peerSPKI {
                try await acceptPairing(status.approverKeySet, pending: pending, attempt: attempt)
                connection.cancel(); start(); return
            }
            guard status.state == .pending else {
                throw RelayFailure(.permissionDenied, "No saved comparison matches the Mac's approval. Start a new pairing on the Mac.")
            }
            _ = try parsedKeys(status.approverKeySet)
            let transcript = RelayCrypto.pairTranscript(relaySPKI: connection.peerSPKI, approverSPKI: identity.publicKeySPKI,
                                                        signingKey: publicKey, keySet: status.approverKeySet.keySet, encryptionKey: request.pairApprover.key.encryptionPublicKey)
            let pending = PhonePendingPair(endpoint: endpoint, relaySPKI: connection.peerSPKI,
                                           previousKeySet: try status.approverKeySet.serializedData(), transcript: transcript)
            var next = state; next.pendingPair = pending; try commit(next)
            logger.notice("Pairing comparison saved; awaiting Mac-signed addition")
            pairing = .comparing(fingerprint: RelayCrypto.fingerprint(transcript), relayAddress: address(endpoint)); publish()
            pairConnection = connection
            pairTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let response = try await connection.next()
                        guard let self, self.pairingAttempt == attempt else { connection.cancel(); return }
                        guard case let .enrolStatus(status) = response.response else { throw RelayFailure(.unavailable, "Unexpected pairing response.") }
                        if status.state == .approved {
                            try await self.acceptPairing(status.approverKeySet, pending: pending, attempt: attempt)
                            connection.cancel(); self.pairConnection = nil; self.pairTask = nil
                            self.start(); return
                        }
                        guard status.state == .pending else { throw RelayFailure(.conflict, "The comparison expired or changed. Start pairing again.") }
                        guard status.approverKeySet.keySet == (try Agentkeyring_V1_SignedApproverKeySet(serializedBytes: pending.previousKeySet)).keySet else {
                            throw RelayFailure(.conflict, "The approver keys changed. Compare a new fingerprint.")
                        }
                    }
                } catch {
                    if !Task.isCancelled, self?.pairingAttempt == attempt { self?.pairing = .failed("Pairing interrupted. Start again and compare the full fingerprint."); self?.fail(error, stage: "Pairing") }
                    connection.cancel()
                }
            }
        } catch {
            connection.cancel()
            if pairingAttempt == attempt { pairing = .failed("Pairing could not start. Check the relay and Tailscale."); publish() }
            throw error
        }
    }

    public func cancelPairing() {
        pairingAttempt = UUID()
        pairingStartTask?.cancel(); pairingStartTask = nil
        pairTask?.cancel(); pairTask = nil; pairConnection?.cancel(); pairConnection = nil
        if state.keySet == nil {
            var next = state; next.pairingWanted = false
            do { try commit(next) } catch { fail(error, stage: "Cancel pairing") }
            // Keep the comparison receipt so an accepted pairing can recover if its acknowledgement was lost.
            pairing = .notPaired; publish()
        }
    }

    func acceptPairing(_ signed: Agentkeyring_V1_SignedApproverKeySet, pending: PhonePendingPair, attempt: UUID) async throws {
        let previous = try parsedKeys(Agentkeyring_V1_SignedApproverKeySet(serializedBytes: pending.previousKeySet))
        let nextSet = try parsedKeys(signed)
        try verify(signed.signature, bytes: signed.keySet, signerID: signed.signerKeyID, in: previous)
        if let replacement = state.replacementPairing {
            guard !nextSet.keys.contains(where: { $0.keyID == replacement.previousKeyID }) else {
                throw RelayFailure(.permissionDenied, "Replace the previous iPhone on your Mac before completing this pairing.")
            }
        }
        logger.notice("Mac signature on added approver verified")
        let ownKey = try keys.signingPublicKey()
        guard state.pendingPair?.transcript == pending.transcript,
              nextSet.revision > previous.revision, nextSet.ruleOwnerKeyID == previous.ruleOwnerKeyID,
              nextSet.pairingTranscriptSha256 == RelayCrypto.hash(pending.transcript),
              nextSet.keys.contains(where: { $0.role == .phone && $0.keyID == RelayCrypto.keyID(ownKey) && $0.publicKey == ownKey && $0.tlsPublicKey == (try? identityProvider().publicKeySPKI) && $0.encryptionPublicKey == (try? keys.encryptionPublicKey()) }),
              nextSet.configurationRevision > 0, nextSet.configurationSha256.count == 32 else {
            throw RelayFailure(.permissionDenied, "The Mac's signed pairing does not match this phone's comparison.")
        }
        let client = RelayTransport(endpoint: pending.endpoint, identity: try identityProvider(), pin: pending.relaySPKI)
        var request = Agentkeyring_V1_RelayWireRequest(); request.getConfiguration = .init()
        let response = try await client.call(request)
        guard case let .configuration(configuration) = response.response else { throw RelayFailure(.unavailable, "The Mac's signed configuration is unavailable.") }
        let parsed = try verifiedConfiguration(configuration, keys: nextSet)
        guard parsed.revision == nextSet.configurationRevision,
              RelayCrypto.hash(configuration.configuration) == nextSet.configurationSha256 else {
            throw RelayFailure(.permissionDenied, "The configuration differs from the one the Mac approved for pairing.")
        }
        try Task.checkCancellation()
        guard pairingAttempt == attempt, state.pendingPair?.transcript == pending.transcript else { throw CancellationError() }
        var next = state; next.endpoint = pending.endpoint; next.relaySPKI = pending.relaySPKI
        next.keySet = try signed.serializedData(); next.configuration = try configuration.serializedData()
        next.rulesUpdatedAt = Date(); next.pendingPair = nil; next.pairingWanted = false; next.replacementPairing = nil
        try commit(next); pairing = .paired; lastFailure = nil; publish()
        logger.notice("Accepted Mac-signed approver addition and configuration; revision=\(parsed.revision, privacy: .public) machines=\(parsed.machines.count, privacy: .public)")
    }

    func verifiedConfiguration(_ signed: Agentkeyring_V1_SignedConfiguration, keys: Agentkeyring_V1_ApproverKeySet) throws -> Agentkeyring_V1_Configuration {
        guard signed.approverKeyID == keys.ruleOwnerKeyID else {
            throw RelayFailure(.permissionDenied, "Only the rule owner may sign the configuration.")
        }
        try verify(signed.signature, bytes: signed.configuration, signerID: signed.approverKeyID, in: keys)
        let configuration = try Agentkeyring_V1_Configuration(serializedBytes: signed.configuration)
        let loginIDs = configuration.logins.map(\.loginID)
        guard configuration.domain == "agentkeyring.configuration.v1", configuration.revision > 0,
              !loginIDs.contains(""), Set(loginIDs).count == loginIDs.count,
              configuration.logins.allSatisfy({ [.ask, .automatic, .blocked].contains($0.rule) }),
              Set(configuration.machines.map(\.recipientID)).count == configuration.machines.count else {
            throw RelayFailure(.permissionDenied, "The signed configuration is invalid.")
        }
        for machine in configuration.machines {
            guard !machine.recipientID.isEmpty, !machine.machineLabel.isEmpty, !machine.tailscaleNodeID.isEmpty,
                  !machine.tlsPublicKey.isEmpty, machine.receiverKeyID == RelayCrypto.keyID(machine.receiverPublicKey) else {
                throw RelayFailure(.permissionDenied, "A configured machine has invalid identity or keys.")
            }
            _ = try P256.KeyAgreement.PublicKey(x963Representation: machine.receiverPublicKey)
        }
        if !configuration.automaticSigningPublicKey.isEmpty || !configuration.automaticKeyID.isEmpty {
            guard configuration.automaticKeyID == RelayCrypto.keyID(configuration.automaticSigningPublicKey) else {
                throw RelayFailure(.permissionDenied, "The configured Automatic key is invalid.")
            }
            _ = try P256.Signing.PublicKey(x963Representation: configuration.automaticSigningPublicKey)
        }
        return configuration
    }

    public func refreshAuthority() async throws {
        if let task = authorityTask { return try await task.value }
        let task = Task { try await refreshAuthorityUnshared() }
        authorityTask = task
        defer { authorityTask = nil }
        try await task.value
    }

    private func refreshAuthorityUnshared() async throws {
        let client = try transport()
        let set = try parsedKeys(currentKeys())
        var request = Agentkeyring_V1_RelayWireRequest(); request.getApproverKeyChain.fromRevision = set.revision
        let chain = try await client.call(request)
        guard case let .approverKeyChain(chain) = chain.response else { throw RelayFailure(.unavailable, "The approver key chain is unavailable.") }
        for signed in chain.keySets {
            try applyApproverKeys(signed)
        }
        try applyApproverKeys(currentKeys())
        request = .init(); request.getConfigurationUpdates.afterRevision = (try? configuration().revision) ?? 0
        let response = try await client.call(request)
        guard case let .configurationUpdates(updates) = response.response, !updates.configurations.isEmpty else {
            throw RelayFailure(.unavailable, "The Mac's signed configuration updates are unavailable.")
        }
        for signed in updates.configurations { try applyConfiguration(signed) }
    }

    func applyConfiguration(_ configuration: Agentkeyring_V1_SignedConfiguration) throws {
        let currentSet = try parsedKeys(currentKeys())
        let parsed = try verifiedConfiguration(configuration, keys: currentSet)
        if let bytes = state.configuration {
            let previous = try Agentkeyring_V1_SignedConfiguration(serializedBytes: bytes)
            let old = try Agentkeyring_V1_Configuration(serializedBytes: previous.configuration)
            guard parsed.revision >= old.revision,
                  parsed.revision != old.revision || configuration.configuration == previous.configuration else {
                throw RelayFailure(.permissionDenied, "The configuration rolled back or changed at the same revision.")
            }
        }
        try Task.checkCancellation()
        var next = state
        next.configuration = try configuration.serializedData(); next.rulesUpdatedAt = Date()
        if let bytes = next.copy?.signedUpdate {
            let copy = try Agentkeyring_V1_SignedCopyUpdate(serializedBytes: bytes)
            let update = try Agentkeyring_V1_CopyUpdate(serializedBytes: copy.update)
            if update.configurationRevision != parsed.revision || !currentSet.keys.contains(where: { $0.keyID == copy.signerKeyID && $0.role == .macDelivery }) {
                next.copy?.signedUpdate = nil
            }
        }
        try discardWithdrawnRequests(in: &next)
        try queueUpdateReceipt(kind: .configuration, revision: parsed.revision, payload: configuration.configuration, into: &next)
        try commit(next)
        logger.notice("Verified approver chain and rule owner's configuration; revision=\(parsed.revision, privacy: .public) logins=\(parsed.logins.count, privacy: .public) machines=\(parsed.machines.count, privacy: .public)")
    }

    func applyApproverKeys(_ signed: Agentkeyring_V1_SignedApproverKeySet) throws {
        let previous = try parsedKeys(currentKeys())
        let candidate = try parsedKeys(signed)
        if candidate.revision == previous.revision {
            guard signed.keySet == (try currentKeys()).keySet else {
                throw RelayFailure(.permissionDenied, "The approver keys changed at the same revision.")
            }
            var next = state
            try queueUpdateReceipt(kind: .approverKeys, revision: candidate.revision, payload: signed.keySet, into: &next)
            try commit(next)
            return
        }
        guard candidate.revision > previous.revision,
              candidate.keys.allSatisfy({ $0.role != .unspecified || ($0.keyID == previous.ruleOwnerKeyID && $0.publicKey == previous.keys.first(where: { $0.keyID == previous.ruleOwnerKeyID })?.publicKey) }) else {
            throw RelayFailure(.permissionDenied, "The approver key chain rolled back.")
        }
        try verify(signed.signature, bytes: signed.keySet, signerID: signed.signerKeyID, in: previous)
        try Task.checkCancellation()
        let ownKey = try keys.signingPublicKey()
        let isApprover = candidate.keys.contains { $0.role == .phone && $0.publicKey == ownKey && $0.tlsPublicKey == (try? identityProvider().publicKeySPKI) && ($0.encryptionPublicKey.isEmpty || $0.encryptionPublicKey == (try? keys.encryptionPublicKey())) }
        var next = state; next.keySet = try signed.serializedData()
        if !isApprover {
            next.removedKeyID = RelayCrypto.keyID(ownKey)
            next.copy = nil; next.configuration = nil; next.rulesUpdatedAt = nil
            next.requests = [:]; next.remoteLeases = [:]; next.outbox = []
        } else if let bytes = next.copy?.signedUpdate {
            let copy = try Agentkeyring_V1_SignedCopyUpdate(serializedBytes: bytes)
            if !candidate.keys.contains(where: { $0.keyID == copy.signerKeyID && $0.role == .macDelivery }) {
                next.copy?.signedUpdate = nil
            }
        }
        if isApprover {
            try discardWithdrawnRequests(in: &next)
            try queueUpdateReceipt(kind: .approverKeys, revision: candidate.revision, payload: signed.keySet, into: &next)
        }
        try commit(next)
        logger.notice("Saved verified approver keys; revision=\(candidate.revision, privacy: .public) removed=\(!isApprover, privacy: .public)")
        if !isApprover {
            stop(); pairing = .notPaired; connection = .notPaired; publish()
            throw RelayFailure(.permissionDenied, "This iPhone is no longer an approver.")
        }
    }

    func configuration() throws -> Agentkeyring_V1_Configuration {
        guard let bytes = state.configuration else { throw RelayFailure(.unavailable, "The Mac's configuration has not arrived.") }
        let signed = try Agentkeyring_V1_SignedConfiguration(serializedBytes: bytes)
        return try Agentkeyring_V1_Configuration(serializedBytes: signed.configuration)
    }

    func configuredLogin(_ id: String) throws -> Agentkeyring_V1_Login {
        guard let login = try configuration().logins.first(where: { $0.loginID == id }) else {
            throw RelayFailure(.notFound, "The Mac's configuration has no such login.")
        }
        return login
    }

    func sourceMac(_ id: String) throws -> Agentkeyring_V1_ApproverKey {
        let set = try parsedKeys(currentKeys())
        guard let mac = set.keys.first(where: { $0.keyID == id }),
              mac.role == .mac || (mac.role == .unspecified && id == set.ruleOwnerKeyID) else {
            throw RelayFailure(.permissionDenied, "The escalating Mac is no longer trusted.")
        }
        return mac
    }

    func machine(_ recipientID: String) throws -> Agentkeyring_V1_EnrolledMachine {
        guard let machine = try configuration().machines.first(where: { $0.recipientID == recipientID }) else {
            throw RelayFailure(.permissionDenied, "The receiving machine is no longer enrolled.")
        }
        return machine
    }
}
