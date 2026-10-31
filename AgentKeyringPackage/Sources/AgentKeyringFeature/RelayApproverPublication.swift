import AgentKeyringProtocol
import Foundation
import LocalAuthentication

extension RelayApprover {
    public func publishCurrentRules(context: LAContext = LAContext()) async throws {
        try load()
        _ = try currentKeySet()
        try claimAuthorization("publication")
        defer { authorizationID = nil }
        try await keys().1.authorize(context: context, reason: "Apply your Agent Keyring rules and allowed machines")
        let vault = try await credentialSource()
        try Task.checkCancellation()
        try applyConfirmedRules(vault, context: context)
        start()
        await flushOutbox()
        await retryPendingRules()
    }

    // The rules controller supplies the same owner context used to save rules.
    // Configuration, local revocations and the publication share one checkpoint.
    func applyConfirmedRules(_ vault: RelayApproverVault, context: LAContext, rules: CredentialLeaseStore.SavedRules? = nil) throws {
        try load()
        guard state.keySet != nil else {
            try commit(state, vault: vault, rules: rules)
            return
        }
        var next = state
        try preparePublication(next: &next, vault: vault, context: context)
        try commit(next, vault: vault, rules: rules)
        rulesDifferFromConfiguration = false
        publish()
    }

    public func noteRulesChanged() {
        guard loaded, state.keySet != nil else { return }
        rulesAreBeingChecked = true
        rulesCheckGeneration += 1
        let generation = rulesCheckGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let vault = try await self.credentialSource()
                guard generation == self.rulesCheckGeneration else { return }
                let changed = self.state.publicationDigest != self.publicationDigest(vault, machines: self.state.machines)
                self.rulesDifferFromConfiguration = changed
                if changed { self.errorMessage = "Confirm your current rules to apply them to other machines." }
                self.rulesAreBeingChecked = false
                for id in self.state.requests.keys.sorted() { try self.decideByRule(id, vault: vault) }
                self.publish()
            } catch { self.rulesAreBeingChecked = false; self.report(error) }
        }
    }

    func retryPendingRules() async {
        do {
            let vault = try await credentialSource()
            for id in state.requests.keys.sorted() { try decideByRule(id, vault: vault) }
        } catch { report(error) }
    }

    func publicationDigest(_ vault: RelayApproverVault, machines: [String: Data]) -> Data {
        var parts = [Data(vault.generation.id.uuidString.utf8)]
        for item in vault.generation.items.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts += [Data(item.id.uuidString.utf8), Data(vault.policies[item.id, default: .ask].rawValue.utf8)]
        }
        for id in machines.keys.sorted() { parts += [Data(id.utf8), machines[id]!] }
        return RelayCrypto.hash(RelayCrypto.transcript(parts))
    }

    func preparePublication(next: inout RelayApproverState, vault: RelayApproverVault, context: LAContext) throws {
        let signer = try keys().1
        let ownerID = RelayCrypto.keyID(signer.publicKey)
        guard let keySet = next.keySet else { throw LeaseFailure(.permissionDenied, "This Mac is not paired.") }
        let current = try Agentkeyring_V1_ApproverKeySet(serializedBytes: Agentkeyring_V1_SignedApproverKeySet(serializedBytes: keySet).keySet)
        guard current.ruleOwnerKeyID == ownerID else { throw LeaseFailure(.permissionDenied, "Only the current rule owner can publish rules.") }
        try includeDeliveryKey(next: &next, context: context)
        var configuration = Agentkeyring_V1_Configuration()
        configuration.domain = "agentkeyring.configuration.v1"
        configuration.revision = try currentConfiguration()?.revision ?? 0
        configuration.revision += 1
        configuration.mirrorRefreshedUnixSeconds = Int64(vault.generation.sourceExportedAt.timeIntervalSince1970)
        for item in vault.generation.items.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let candidate = CredentialResolver().candidate(for: item)
            var login = Agentkeyring_V1_Login()
            login.loginID = item.id.uuidString
            login.title = item.title
            login.sites = item.origins
            login.account = candidate.username ?? ""
            login.hasOneTimeCode_p = candidate.availableFields.contains(.totp)
            switch vault.policies[item.id, default: .ask] {
            case .ask: login.rule = .ask
            case .allowAutomatically: login.rule = .automatic
            case .block: login.rule = .blocked
            }
            configuration.logins.append(login)
            var source = Agentkeyring_V1_LoginSource()
            source.loginID = login.loginID
            source.appleItemID = item.sourceIdentity.itemID
            source.appleAccountID = item.sourceIdentity.accountID
            source.exporterIdentifier = item.sourceIdentity.exporterIdentifier
            configuration.sources.append(source)
        }
        configuration.machines = try next.machines.keys.sorted().map { try Agentkeyring_V1_EnrolledMachine(serializedBytes: next.machines[$0]!) }
        configuration.automaticSigningPublicKey = signer.automaticPublicKey
        configuration.automaticKeyID = RelayCrypto.keyID(signer.automaticPublicKey)
        var signed = Agentkeyring_V1_SignedConfiguration()
        signed.configuration = try configuration.serializedData()
        signed.signature = try signer.sign(signed.configuration, context: context, automatic: false)
        signed.approverKeyID = ownerID
        next.configuration = try signed.serializedData()
        next.publicationDigest = publicationDigest(vault, machines: next.machines)
        try revokeAffectedRequests(&next, configuration: configuration)
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishConfiguration.configuration = signed
        try enqueue(command, id: "configuration:\(configuration.revision)", into: &next)
    }

    func includeDeliveryKey(next: inout RelayApproverState, context: LAContext) throws {
        let signer = try keys().1
        guard let keySet = next.keySet else { throw LeaseFailure(.permissionDenied, "This Mac is not paired.") }
        var set = try Agentkeyring_V1_ApproverKeySet(serializedBytes: Agentkeyring_V1_SignedApproverKeySet(serializedBytes: keySet).keySet)
        let id = RelayCrypto.keyID(signer.automaticPublicKey)
        if set.keys.contains(where: { $0.keyID == id && $0.role == .macDelivery }) { return }
        set.keys.removeAll { $0.role == .macDelivery }
        for index in set.keys.indices where set.keys[index].keyID == set.ruleOwnerKeyID { set.keys[index].role = .mac }
        var key = Agentkeyring_V1_ApproverKey()
        key.keyID = id
        key.publicKey = signer.automaticPublicKey
        key.label = "Mac background delivery"
        key.role = .macDelivery
        set.keys.append(key)
        set.revision += 1
        set.pairingTranscriptSha256 = Data()
        var signed = Agentkeyring_V1_SignedApproverKeySet()
        signed.keySet = try set.serializedData()
        signed.signature = try signer.sign(signed.keySet, context: context, automatic: false)
        signed.signerKeyID = RelayCrypto.keyID(signer.publicKey)
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishApproverKeys = signed
        try enqueue(command, id: "delivery-key:\(set.revision)", into: &next)
        next.keySet = try signed.serializedData()
    }

    func currentConfiguration() throws -> Agentkeyring_V1_Configuration? {
        guard let bytes = state.configuration else { return nil }
        return try Agentkeyring_V1_Configuration(serializedBytes: Agentkeyring_V1_SignedConfiguration(serializedBytes: bytes).configuration)
    }

    func revokeAffectedRequests(_ next: inout RelayApproverState, configuration: Agentkeyring_V1_Configuration) throws {
        for (id, saved) in next.requests {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            guard !lease.state.isTerminal else { continue }
            let login = configuration.logins.first { $0.loginID == lease.loginID }
            let machine = configuration.machines.first { $0.recipientID == lease.recipient.recipientID }
            var withdrawn = login == nil || login?.rule == .blocked || machine == nil
            if lease.approvedBy == .automaticRule {
                withdrawn = withdrawn || login?.rule != .automatic || machine?.automaticAllowed != true
            }
            if let bytes = saved.decision {
                let decision = try Agentkeyring_V1_SignedDecision(serializedBytes: bytes)
                let statement = try Agentkeyring_V1_DecisionStatement(serializedBytes: decision.statement)
                if statement.authority == .automaticRule {
                    withdrawn = withdrawn || login?.rule != .automatic || machine?.automaticAllowed != true
                        || decision.approverKeyID != configuration.automaticKeyID
                }
            }
            if withdrawn {
                lease.state = .revoked
                lease.endedAtUnixSeconds = Self.now
                next.requests[id]!.lease = try lease.serializedData()
                next.requests[id]!.decision = nil
                next.outbox.removeAll { $0.id == "decision:" + id || $0.id == "escalation:" + lease.leaseID }
            }
        }
    }
}
