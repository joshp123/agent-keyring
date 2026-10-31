import AgentKeyringProtocol
import Foundation
import LocalAuthentication

extension RelayApprover {
    public func publishCurrentRules(context: LAContext = LAContext()) async throws {
        try load()
        _ = try currentKeySet()
        try claimAuthorization("publication")
        defer { authorizationID = nil }
        let signer = try keys().1
        try await signer.authorize(context: context, reason: "Publish your current Agent Keyring rules and allowed machines")
        let vault = try await credentialSource()
        try Task.checkCancellation()
        var next = state
        try preparePublication(next: &next, vault: vault, context: context)
        try commit(next)
        needsPublication = false
        publish()
        start()
        await flushOutbox()
        await retryPendingRules()
    }

    public func noteRulesChanged() {
        guard loaded, state.keySet != nil else { return }
        needsPublication = true
        rulesAreBeingChecked = true
        rulesCheckGeneration += 1
        let generation = rulesCheckGeneration
        publish()
        Task { [weak self] in
            guard let self else { return }
            do {
                let vault = try await self.credentialSource()
                guard generation == self.rulesCheckGeneration else { return }
                self.needsPublication = self.state.publicationDigest != self.publicationDigest(vault, machines: self.state.machines)
                try self.reconcileLocalRequests(vault)
                self.rulesAreBeingChecked = false
                for id in self.state.requests.keys.sorted() { try self.decideByRule(id, vault: vault) }
                self.publish()
            } catch { self.report(error) }
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
        let keySet = try Agentkeyring_V1_ApproverKeySet(serializedBytes: currentKeySet().keySet)
        guard keySet.ruleOwnerKeyID == ownerID else { throw LeaseFailure(.permissionDenied, "Only the current rule owner can publish rules.") }
        var index = Agentkeyring_V1_LoginIndex()
        index.revision = next.indexRevision + 1
        index.mirrorRefreshedUnixSeconds = Int64(vault.generation.sourceExportedAt.timeIntervalSince1970)
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
            index.logins.append(login)
            var source = Agentkeyring_V1_LoginSource()
            source.loginID = login.loginID
            source.appleItemID = item.sourceIdentity.itemID
            source.appleAccountID = item.sourceIdentity.accountID
            source.exporterIdentifier = item.sourceIdentity.exporterIdentifier
            index.sources.append(source)
        }
        var signedIndex = Agentkeyring_V1_SignedIndex()
        signedIndex.index = try index.serializedData()
        signedIndex.signature = try signer.sign(signedIndex.index, context: context, automatic: false)
        signedIndex.approverKeyID = ownerID
        var roster = Agentkeyring_V1_EnrolmentSet()
        roster.domain = "agentkeyring.enrolments.v1"
        roster.revision = next.rosterRevision + 1
        roster.machines = try next.machines.keys.sorted().map { try Agentkeyring_V1_EnrolledMachine(serializedBytes: next.machines[$0]!) }
        var signedRoster = Agentkeyring_V1_SignedEnrolmentSet()
        signedRoster.enrolmentSet = try roster.serializedData()
        signedRoster.signature = try signer.sign(signedRoster.enrolmentSet, context: context, automatic: false)
        signedRoster.approverKeyID = ownerID
        var grant = Agentkeyring_V1_AutomaticGrant()
        grant.domain = "agentkeyring.automatic.v1"
        grant.revision = next.grantRevision + 1
        grant.automaticSigningPublicKey = signer.automaticPublicKey
        grant.automaticKeyID = RelayCrypto.keyID(signer.automaticPublicKey)
        grant.loginIds = index.logins.filter { $0.rule == .automatic }.map(\.loginID)
        grant.recipientIds = roster.machines.filter(\.automaticAllowed).map(\.recipientID)
        var signedGrant = Agentkeyring_V1_SignedAutomaticGrant()
        signedGrant.grant = try grant.serializedData()
        signedGrant.signature = try signer.sign(signedGrant.grant, context: context, automatic: false)
        signedGrant.approverKeyID = ownerID
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishIndex = signedIndex
        try enqueue(command, id: "index:\(index.revision)", into: &next)
        command = Agentkeyring_V1_RelayWireRequest()
        command.publishEnrolmentSet = signedRoster
        try enqueue(command, id: "roster:\(roster.revision)", into: &next)
        command = Agentkeyring_V1_RelayWireRequest()
        command.publishAutomaticGrant = signedGrant
        try enqueue(command, id: "grant:\(grant.revision)", into: &next)
        next.index = try signedIndex.serializedData()
        next.enrolmentSet = try signedRoster.serializedData()
        next.automaticGrant = try signedGrant.serializedData()
        next.indexRevision = index.revision
        next.rosterRevision = roster.revision
        next.grantRevision = grant.revision
        next.publicationDigest = publicationDigest(vault, machines: next.machines)
    }

    func reconcileLocalRequests(_ vault: RelayApproverVault) throws {
        var next = state
        for (id, saved) in state.requests {
            var lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            guard lease.state == .active || lease.state == .pending else { continue }
            let uuid = UUID(uuidString: lease.loginID)
            let missing = !vault.generation.items.contains { $0.id == uuid }
            let policy = uuid.map { vault.policies[$0, default: .ask] } ?? .block
            if missing || policy == .block || (lease.approvedBy == .automaticRule && policy != .allowAutomatically) {
                lease.state = .revoked
                lease.endedAtUnixSeconds = Self.now
                next.requests[id]!.lease = try lease.serializedData()
                // A locally revoked approval that has not left the outbox must
                // not become a new delivery after a rule or machine change.
                next.outbox.removeAll { $0.id == "decision:" + id }
            }
        }
        try commit(next)
    }
}
