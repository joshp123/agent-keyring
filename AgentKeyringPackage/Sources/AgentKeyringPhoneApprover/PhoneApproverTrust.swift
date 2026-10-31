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

    public func beginPairing(endpoint: RelayEndpoint) async throws {
        try load()
        guard state.keySet == nil else { throw RelayFailure(.conflict, "This iPhone is already paired.") }
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
        request.pairApprover.tlsPublicKey = identity.publicKeySPKI
        let connection = try await RelayTransport(endpoint: endpoint, identity: identity, pin: nil).open(request)
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
                                                        signingKey: publicKey, keySet: status.approverKeySet.keySet)
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
        logger.notice("Mac signature on added approver verified")
        let ownKey = try keys.signingPublicKey()
        guard state.pendingPair?.transcript == pending.transcript,
              nextSet.revision > previous.revision, nextSet.ruleOwnerKeyID == previous.ruleOwnerKeyID,
              nextSet.pairingTranscriptSha256 == RelayCrypto.hash(pending.transcript),
              nextSet.keys.contains(where: { $0.role == .phone && $0.keyID == RelayCrypto.keyID(ownKey) && $0.publicKey == ownKey && $0.tlsPublicKey == (try? identityProvider().publicKeySPKI) }),
              nextSet.enrolmentSetRevision > 0, nextSet.enrolmentSetSha256.count == 32 else {
            throw RelayFailure(.permissionDenied, "The Mac's signed pairing does not match this phone's comparison.")
        }
        let client = RelayTransport(endpoint: pending.endpoint, identity: try identityProvider(), pin: pending.relaySPKI)
        var request = Agentkeyring_V1_RelayWireRequest(); request.getEnrolmentSet = .init()
        let response = try await client.call(request)
        guard case let .enrolmentSet(roster) = response.response else { throw RelayFailure(.unavailable, "The signed machine list is unavailable.") }
        let parsed = try verifiedRoster(roster, keys: nextSet)
        guard parsed.revision == nextSet.enrolmentSetRevision,
              RelayCrypto.hash(roster.enrolmentSet) == nextSet.enrolmentSetSha256 else {
            throw RelayFailure(.permissionDenied, "The machine list differs from the one the Mac approved for pairing.")
        }
        try Task.checkCancellation()
        guard pairingAttempt == attempt, state.pendingPair?.transcript == pending.transcript else { throw CancellationError() }
        var next = state; next.endpoint = pending.endpoint; next.relaySPKI = pending.relaySPKI
        next.keySet = try signed.serializedData(); next.roster = try roster.serializedData(); next.pendingPair = nil; next.pairingWanted = false
        try commit(next); pairing = .paired; lastFailure = nil; publish()
        logger.notice("Accepted Mac-signed approver addition and pinned machine roster; machines=\(parsed.machines.count, privacy: .public)")
    }

    func verifiedRoster(_ signed: Agentkeyring_V1_SignedEnrolmentSet, keys: Agentkeyring_V1_ApproverKeySet) throws -> Agentkeyring_V1_EnrolmentSet {
        guard signed.approverKeyID == keys.ruleOwnerKeyID else {
            throw RelayFailure(.permissionDenied, "Only the rule owner may sign the machine list.")
        }
        try verify(signed.signature, bytes: signed.enrolmentSet, signerID: signed.approverKeyID, in: keys)
        let roster = try Agentkeyring_V1_EnrolmentSet(serializedBytes: signed.enrolmentSet)
        guard roster.domain == "agentkeyring.enrolments.v1", roster.revision > 0,
              Set(roster.machines.map(\.recipientID)).count == roster.machines.count else {
            throw RelayFailure(.permissionDenied, "The signed machine list is invalid.")
        }
        for machine in roster.machines {
            guard !machine.recipientID.isEmpty, !machine.machineLabel.isEmpty, !machine.tailscaleNodeID.isEmpty,
                  !machine.tlsPublicKey.isEmpty, machine.receiverKeyID == RelayCrypto.keyID(machine.receiverPublicKey) else {
                throw RelayFailure(.permissionDenied, "A signed machine has invalid identity or keys.")
            }
            _ = try P256.KeyAgreement.PublicKey(x963Representation: machine.receiverPublicKey)
        }
        return roster
    }

    func refreshAuthority() async throws {
        if let task = authorityTask { return try await task.value }
        let task = Task { try await refreshAuthorityUnshared() }
        authorityTask = task
        defer { authorityTask = nil }
        try await task.value
    }

    private func refreshAuthorityUnshared() async throws {
        let client = try transport()
        var current = try currentKeys()
        var set = try parsedKeys(current)
        var request = Agentkeyring_V1_RelayWireRequest(); request.getApproverKeyChain.fromRevision = set.revision
        let chain = try await client.call(request)
        guard case let .approverKeyChain(chain) = chain.response else { throw RelayFailure(.unavailable, "The approver key chain is unavailable.") }
        for signed in chain.keySets {
            let candidate = try parsedKeys(signed)
            guard candidate.revision > set.revision,
                  candidate.keys.allSatisfy({ $0.role != .unspecified || ($0.keyID == set.ruleOwnerKeyID && $0.publicKey == set.keys.first(where: { $0.keyID == set.ruleOwnerKeyID })?.publicKey) }) else { throw RelayFailure(.permissionDenied, "The approver key chain rolled back.") }
            try verify(signed.signature, bytes: signed.keySet, signerID: signed.signerKeyID, in: set)
            current = signed; set = candidate
        }
        let ownKey = try keys.signingPublicKey()
        guard set.keys.contains(where: { $0.role == .phone && $0.publicKey == ownKey && $0.tlsPublicKey == (try? identityProvider().publicKeySPKI) }) else {
            throw RelayFailure(.permissionDenied, "This iPhone is no longer an approver.")
        }
        request = .init(); request.getEnrolmentSet = .init()
        let response = try await client.call(request)
        guard case let .enrolmentSet(roster) = response.response else { throw RelayFailure(.unavailable, "The signed machine list is unavailable.") }
        let parsed = try verifiedRoster(roster, keys: set)
        if let bytes = state.roster {
            let old = try Agentkeyring_V1_SignedEnrolmentSet(serializedBytes: bytes)
            let previous = try Agentkeyring_V1_EnrolmentSet(serializedBytes: old.enrolmentSet)
            guard parsed.revision >= previous.revision,
                  parsed.revision != previous.revision || old.enrolmentSet == roster.enrolmentSet else {
                throw RelayFailure(.permissionDenied, "The machine list rolled back or changed at the same revision.")
            }
        }
        logger.notice("Approver chain and machine roster verified; revision=\(set.revision, privacy: .public) machines=\(parsed.machines.count, privacy: .public)")
        var next = state; next.keySet = try current.serializedData(); next.roster = try roster.serializedData()
        try commit(next)
        guard let owner = set.keys.first(where: { $0.keyID == set.ruleOwnerKeyID }) else { throw RelayFailure(.permissionDenied, "No rule owner.") }
        request = .init(); request.getIndex = .init()
        let index = try await client.call(request)
        guard case let .index(index) = index.response else { throw RelayFailure(.unavailable, "The rule owner's index is unavailable.") }
        guard index.approverKeyID == owner.keyID else { throw RelayFailure(.permissionDenied, "Only the rule owner may sign the login index.") }
        try verify(index.signature, bytes: index.index, signerID: index.approverKeyID, in: set)
        let parsedIndex = try Agentkeyring_V1_LoginIndex(serializedBytes: index.index)
        let ids = parsedIndex.logins.map(\.loginID)
        guard parsedIndex.revision > 0, !ids.contains(""), Set(ids).count == ids.count,
              parsedIndex.logins.allSatisfy({ [.ask, .automatic, .blocked].contains($0.rule) }) else {
            throw RelayFailure(.permissionDenied, "The signed login index is invalid.")
        }
        if let bytes = state.signedIndex {
            let previous = try Agentkeyring_V1_SignedIndex(serializedBytes: bytes)
            let oldIndex = try Agentkeyring_V1_LoginIndex(serializedBytes: previous.index)
            guard parsedIndex.revision >= oldIndex.revision,
                  parsedIndex.revision != oldIndex.revision || index.index == previous.index else {
                throw RelayFailure(.permissionDenied, "The login index rolled back or changed at the same revision.")
            }
        }
        next = state; next.signedIndex = try index.serializedData(); next.rulesUpdatedAt = Date()
        try commit(next)
        logger.notice("Verified rule owner index; logins=\(parsedIndex.logins.count, privacy: .public)")
    }

    func indexedLogin(_ id: String) throws -> Agentkeyring_V1_Login {
        guard let bytes = state.signedIndex else { throw RelayFailure(.unavailable, "The Mac's login index has not arrived.") }
        let signed = try Agentkeyring_V1_SignedIndex(serializedBytes: bytes)
        let index = try Agentkeyring_V1_LoginIndex(serializedBytes: signed.index)
        guard let login = index.logins.first(where: { $0.loginID == id }) else {
            throw RelayFailure(.notFound, "The Mac's signed index has no such login.")
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
        guard let bytes = state.roster else { throw RelayFailure(.permissionDenied, "No trusted machine list.") }
        let signed = try Agentkeyring_V1_SignedEnrolmentSet(serializedBytes: bytes)
        let roster = try Agentkeyring_V1_EnrolmentSet(serializedBytes: signed.enrolmentSet)
        guard let machine = roster.machines.first(where: { $0.recipientID == recipientID }) else {
            throw RelayFailure(.permissionDenied, "The receiving machine is no longer enrolled.")
        }
        return machine
    }
}
