// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Each password sealed separately to each key that may open it: this Mac's
// chip key always; the receiving key of every enrolled computer (this Mac
// included) when its rule is Automatic; and the other approving devices.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MacKeyringEngine {
    /// True when this Mac may hold local Automatic copies: either standalone (no Members yet)
    /// or still listed as a machine in the current signed Members list.
    var thisMacIsEnrolledMachine: Bool {
        guard let keys = try? macKeys() else { return false }
        guard let members = device?.members else { return true }
        return members.machines.contains { $0.machineID == keys.machineID }
    }

    /// `version` is when the secret was imported; every copy of it carries that.
    /// A Blocked login is never sealed: its secret is deleted everywhere.
    func sealCopies(of secret: Agentkeyring_V2_LoginSecret, version: UInt64, automatic: Bool) throws -> [Agentkeyring_V2_SealedLogin] {
        let keys = try macKeys()
        var openers: [(id: String, key: P256.KeyAgreement.PublicKey)] = [(keys.deviceKeyID, keys.openingPublicKey)]
        if automatic, thisMacIsEnrolledMachine { openers.append((keys.machineID, keys.receiving.publicKey)) }
        openers += device?.otherOpeners(automatic: automatic) ?? []
        return try openers.map { try CredentialSealing.sealLogin(secret, version: version, to: $0.key, openerID: $0.id, signer: keys.signer) }
    }

    /// The Mac's own copy of a login, sealed to its chip key (newest version, or a specific version if given).
    func macCopy(of loginID: String, version: UInt64? = nil) async throws -> Agentkeyring_V2_SealedLogin {
        let keys = try macKeys()
        let matches = try await store.sealed().filter {
            $0.loginID == loginID && $0.openerID == keys.deviceKeyID && (version == nil || $0.version == version)
        }
        guard let copy = matches.max(by: { $0.version < $1.version }) else {
            let deleted = leaseLogins.contains { $0.id.uuidString == loginID && $0.isSecretDeleted }
            throw AgentRPCError(.notFound, deleted ? MessageCopy.secretDeletedOnThisMac : MessageCopy.noCopyOnThisMac)
        }
        do { try keys.check(copy, members: device?.members) } catch {
            throw AgentRPCError(.permissionDenied, "This Mac's copy of this password was not sealed by one of your devices. Copy your passwords again from Passwords.")
        }
        return copy
    }

    /// An opened login only if it was sealed as the login shown for it: the
    /// list on disk is not trusted to say which password a request is for.
    func checkShown(_ secret: Agentkeyring_V2_LoginSecret, as login: CredentialCandidate) throws {
        do { try CredentialSealing.verifyOpenedLoginBinding(secret, title: login.title, sites: login.origins, account: login.username ?? "") } catch {
            throw AgentRPCError(.permissionDenied, "This password's details on this Mac don't match its sealed copy. Copy your passwords again from Passwords.")
        }
    }

    /// A rule change, after Josh's Touch ID: a password switched to Automatic
    /// is opened once and sealed to every enrolled computer (this Mac included);
    /// one switched away loses those copies. The other devices then get the
    /// new rules. A password set to Blocked loses every copy, this Mac's too,
    /// once the change is saved (`deleteSecretsOrReport`): unblocked, it has
    /// no secret until he exports from Passwords again.
    func applyRuleChange(from old: [UUID: LoginRule], to new: [UUID: LoginRule], context: LAContext) async throws {
        let keys = try macKeys()
        let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        let noSecret = Set(leaseLogins.filter(\.isSecretDeleted).map(\.id))
        let machines = Set((thisMacIsEnrolledMachine ? [keys.machineID] : []) + (device?.members?.machines.map(\.machineID) ?? []))
        let automaticChangedIDs = Set(changed.filter { (old[$0] == .automatic) != (new[$0] == .automatic) }.map(\.uuidString))
        var added: [Agentkeyring_V2_SealedLogin] = []
        for id in changed where new[id] == .automatic && old[id] != .blocked && !noSecret.contains(id) {
            let loginID = id.uuidString
            let copy = try await macCopy(of: loginID)
            let secret = try keys.openSealedLogin(copy, context: context)
            added += try sealCopies(of: secret, version: copy.version, automatic: true).filter { machines.contains($0.openerID) }
        }
        let addedKeys = Set(added.map { $0.openerID + "/" + $0.loginID })
        let addedCopies = added
        try await store.updateSealed { current in
            var next = current
            next.removeAll { automaticChangedIDs.contains($0.loginID) && machines.contains($0.openerID) }
            next.removeAll { addedKeys.contains($0.openerID + "/" + $0.loginID) }
            return next + addedCopies
        }
        try await device?.publish(context: context)
        await noteMissingAutomaticCopies()
    }

    /// Blocking deletes the secret: every sealed copy, on this Mac and for
    /// every device and computer, and the list records it, so no older copy
    /// counts again. Only a new export from Passwords brings it back.
    func deleteSecrets(of ids: Set<UUID>, serialized: Bool = true) async throws {
        guard !ids.isEmpty else { return }
        let work: @MainActor () async throws -> Void = { [self] in
            let loginIDs = Set(ids.map(\.uuidString))
            let version = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            guard let current = try await self.store.loadCurrent() else {
                try await self.store.updateSealed { $0.filter { !loginIDs.contains($0.loginID) } }
                return
            }
            let next = current.deletingSecrets(of: ids, at: version)
            try await self.store.save(next) { $0.filter { !loginIDs.contains($0.loginID) } }
            self.status = next.safeStatus
            self.leaseLogins = next.metadata.candidates
            await self.accessControl.refresh(from: next)
            self.device?.cloudSync.pushCloudSoon()
        }
        if serialized, let device {
            try await device.withSerializedCatalogue(work)
        } else {
            try await work()
        }
    }

    /// As `deleteSecrets`, with a failure said on screen; the next launch tries again (`loadStatus`).
    func deleteSecretsOrReport(of ids: Set<UUID>, serialized: Bool = true) async {
        do { try await deleteSecrets(of: ids, serialized: serialized) } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("rules", "delete-failed", ["reason": "\(error)"])
            problem = MessageCopy.secretNotDeleted
        }
    }

    /// Rules from another device's signed catalogue (or, while two of one revision are contested, the two
    /// merged), merged with this Mac's login by login: only what that device changed from `base`, the
    /// catalogue it started from, and the one set last stays, so two changes made at once end the same on
    /// both (`LoginRuleTimestampEntry.received`). Every computer's copies of a password no longer Automatic are withdrawn,
    /// and a Blocked one's secret is deleted. Copies for a password newly Automatic need this Mac's Touch ID
    /// to make (`automaticCopiesMissing`). Throws when the rules, the deletions or the copies could not be saved:
    /// the catalogue is then taken again, and every step here is safe to run twice.
    func adoptCatalogue(_ catalogue: Agentkeyring_V2_Catalogue, base: Agentkeyring_V2_Catalogue?) async throws {
        let keys = try macKeys()
        func entry(_ login: Agentkeyring_V2_Login) -> LoginRuleTimestampEntry {
            LoginRuleTimestampEntry(LoginRule(storedRule: login.rule), updatedAtMs: login.ruleUpdatedUnixMs, actor: login.ruleActor)
        }
        let started = Dictionary((base?.logins ?? []).map { ($0.loginID, entry($0)) }, uniquingKeysWith: { first, _ in first })
        var next = accessControl.entries
        for login in catalogue.logins {
            guard let id = UUID(uuidString: login.loginID) else { continue }
            next[id] = LoginRuleTimestampEntry.received(entry(login), base: started[login.loginID], local: next[id])
        }
        let automatic = Set(next.filter { $0.value.rule == .automatic }.keys.map(\.uuidString))
        let blocked = Set(next.filter { $0.value.rule == .blocked }.keys)
        let newlyBlocked = blocked.filter { id in leaseLogins.contains { $0.id == id && !$0.isSecretDeleted } }
        let blockedIDs = Set(blocked.map(\.uuidString))
        let currentMembers = device?.members
        let computers = Set((currentMembers?.machines ?? []).map(\.machineID))
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let ownMachineID = keys.machineID
        let replyKeyID = keys.replyKeyID
        let replyPublicKey = keys.replyPublicKey
        try accessControl.adopt(next)
        try await deleteSecrets(of: newlyBlocked, serialized: false)
        _ = try await store.updateSealed { current in
            current.filter { copy in
                if blockedIDs.contains(copy.loginID) { return false }
                if computers.contains(copy.openerID) && !automatic.contains(copy.loginID) { return false }
                if copy.openerID == ownMachineID {
                    guard automatic.contains(copy.loginID), let login = listed[copy.loginID],
                          login.loginID == copy.loginID, login.version == copy.version else { return false }
                    if copy.signerKeyID == replyKeyID {
                        return (try? CredentialSealing.verifySealedLogin(copy, by: replyKeyID, publicKey: replyPublicKey)) != nil
                    } else if let currentMembers {
                        return (try? CredentialSealing.verifySealedLogin(copy, members: currentMembers, listed: login)) != nil
                    }
                    return false
                }
                return true
            }
        }
        await noteMissingAutomaticCopies()
    }

    /// Shared validity check for an Automatic copy, used for both local granting and repair detection.
    private func hasValidCopy(loginID: String, openerID: String, version: UInt64, in sealed: [Agentkeyring_V2_SealedLogin], keys: MacKeys) -> Bool {
        sealed.contains { copy in
            copy.loginID == loginID && copy.openerID == openerID && copy.version == version
                && (try? keys.check(copy, members: device?.members)) != nil
        }
    }

    /// Refreshes which Automatic logins are usable locally on this Mac and whether any enrolled computer
    /// lacks a current-version Automatic copy.
    func noteMissingAutomaticCopies() async {
        let hasAutomatic = leaseLogins.contains { accessControl.rule(for: $0.id) == .automatic }
        guard let keys = try? macKeys() else {
            localAutomaticCopyIDs = []
            try? leaseStore.reconcile(logins: leaseLogins, rules: currentRules)
            automaticCopiesMissing = false
            return
        }
        let sealed: [Agentkeyring_V2_SealedLogin]
        do {
            sealed = try await store.sealed()
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("copies", "read-failed", ["reason": "\(error)"])
            localAutomaticCopyIDs = []
            try? leaseStore.reconcile(logins: leaseLogins, rules: currentRules)
            automaticCopiesMissing = hasAutomatic
            return
        }
        let macVersions = Dictionary(
            sealed.filter { $0.openerID == keys.deviceKeyID }.map { ($0.loginID, $0.version) },
            uniquingKeysWith: max
        )
        if thisMacIsEnrolledMachine {
            localAutomaticCopyIDs = Set(leaseLogins.compactMap { login -> String? in
                let loginID = login.id.uuidString
                guard accessControl.rule(for: login.id) == .automatic,
                      let expected = macVersions[loginID],
                      hasValidCopy(loginID: loginID, openerID: keys.machineID, version: expected, in: sealed, keys: keys) else { return nil }
                return loginID
            })
        } else {
            localAutomaticCopyIDs = []
        }
        automaticCopiesChecked = true
        try? leaseStore.reconcile(logins: leaseLogins, rules: currentRules)
        if device?.cloudSync.takingSealedRecords != true {
            automaticCopiesMissing = !(await missingAutomaticCopies(sealed: sealed)).isEmpty
        }
    }

    /// One Automatic password and version with the enrolled computers that lack a valid copy of it.
    struct MissingAutomaticTarget {
        let loginID: String
        let version: UInt64
        let receivers: [(id: String, key: P256.KeyAgreement.PublicKey)]
    }

    /// Each Automatic password version, with the enrolled computers that lack a valid copy of it.
    func missingAutomaticCopies(sealed existing: [Agentkeyring_V2_SealedLogin]? = nil) async -> [MissingAutomaticTarget] {
        guard let keys = try? macKeys() else { return [] }
        let sealed: [Agentkeyring_V2_SealedLogin]
        if let existing { sealed = existing }
        else if let loaded = try? await store.sealed() { sealed = loaded }
        else { return [] }
        let macCopiesByLogin = Dictionary(grouping: sealed.filter { $0.openerID == keys.deviceKeyID }, by: \.loginID)
        let signedVersions = Dictionary(
            (device?.catalogue?.logins ?? []).map { ($0.loginID, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )
        let otherReceivers = (device?.otherOpeners(automatic: true) ?? []).filter { opener in
            device?.members?.machines.contains { $0.machineID == opener.id } == true
        }
        var missing: [MissingAutomaticTarget] = []
        for login in leaseLogins where accessControl.rule(for: login.id) == .automatic {
            let loginID = login.id.uuidString
            let availableVersions = Set((macCopiesByLogin[loginID] ?? []).map(\.version))
            guard let newestVersion = availableVersions.max() else { continue }
            var byVersion: [UInt64: [(id: String, key: P256.KeyAgreement.PublicKey)]] = [:]
            if thisMacIsEnrolledMachine,
               !hasValidCopy(loginID: loginID, openerID: keys.machineID, version: newestVersion, in: sealed, keys: keys) {
                byVersion[newestVersion, default: []].append((id: keys.machineID, key: keys.receiving.publicKey))
            }
            if let signedVersion = signedVersions[loginID], availableVersions.contains(signedVersion) {
                for receiver in otherReceivers where !hasValidCopy(loginID: loginID, openerID: receiver.id, version: signedVersion, in: sealed, keys: keys) {
                    byVersion[signedVersion, default: []].append(receiver)
                }
            }
            for version in byVersion.keys.sorted() {
                if let receivers = byVersion[version], !receivers.isEmpty {
                    missing.append(MissingAutomaticTarget(loginID: loginID, version: version, receivers: receivers))
                }
            }
        }
        return missing
    }

    /// "Not now": asked again after the next rule change on the iPhone.
    public func declineAutomaticCopies() { automaticCopiesMissing = false }

    /// Makes the missing Automatic copies for every enrolled computer, with a context Josh has just approved.
    public func sealAutomaticCopies(context: LAContext) async throws {
        let keys = try macKeys()
        let startMembersRevision = device?.members?.revision
        let startWasEnrolled = thisMacIsEnrolledMachine
        let targets = await missingAutomaticCopies()
        var added: [Agentkeyring_V2_SealedLogin] = []
        for target in targets {
            let copy = try await macCopy(of: target.loginID, version: target.version)
            let secret = try keys.openSealedLogin(copy, context: context)
            added += try target.receivers.map { try CredentialSealing.sealLogin(secret, version: copy.version, to: $0.key, openerID: $0.id, signer: keys.signer) }
        }
        // Discard the batch if membership changed while sealing (for example, iPhone removed this Mac or another computer).
        guard device?.members?.revision == startMembersRevision, thisMacIsEnrolledMachine == startWasEnrolled else {
            await noteMissingAutomaticCopies()
            return
        }
        let addedKeys = Set(added.map { "\($0.openerID)/\($0.loginID)/\($0.version)" })
        let addedCopies = added
        if !addedCopies.isEmpty {
            try await store.updateSealed { current in
                current.filter { !addedKeys.contains("\($0.openerID)/\($0.loginID)/\($0.version)") } + addedCopies
            }
            device?.sendCopies(for: Set((device?.members?.machines ?? []).map(\.machineID)))
        }
        await noteMissingAutomaticCopies()
    }

    /// The logins and their rules, as the other devices see them, each with
    /// the version of this Mac's own newest copy.
    func catalogueLogins() async throws -> [Agentkeyring_V2_Login] {
        let keys = try macKeys()
        let sealed = try await store.sealed()
        let versions = Dictionary(sealed.filter { $0.openerID == keys.deviceKeyID }.map { ($0.loginID, $0.version) },
            uniquingKeysWith: max)
        publishingListSnapshot = currentList
        // A login exported later on another device keeps the version that device listed, whether or not
        // its copy for this Mac has arrived: an older copy here never takes the newer one's place.
        let signed = Dictionary((device?.catalogue?.logins ?? []).map { ($0.loginID, $0.version) }, uniquingKeysWith: { first, _ in first })
        return leaseLogins.map { login in
            var item = Agentkeyring_V2_Login()
            item.loginID = login.id.uuidString
            item.title = login.title
            item.sites = login.origins
            item.account = login.username ?? ""
            item.hasOneTimeCode_p = login.availableFields.contains(.totp)
            item.rule = accessControl.rule(for: login.id).storedRule
            if let entry = accessControl.entries[login.id] {
                item.ruleUpdatedUnixMs = entry.updatedAtMs
                item.ruleActor = entry.actor
            }
            // 0 when no device holds its secret (deleted when it was Blocked).
            item.version = login.isSecretDeleted || item.rule == .blocked ? 0
                : max(versions[login.id.uuidString] ?? 0, signed[login.id.uuidString] ?? 0)
            return item
        }
    }

    /// The values a local lease delivers: from the login opened at approval,
    /// or for an Automatic lease from the Mac's copy sealed to its receiving key.
    func values(for lease: Agentkeyring_V2_Lease, fields: [Agentkeyring_V2_CredentialField]) async throws -> Agentkeyring_V2_CredentialValues {
        guard lease.state == .approved else {
            throw AgentRPCError(.permissionDenied, "The lease is not active. Inspect its status before starting another request.")
        }
        let secret: Agentkeyring_V2_LoginSecret
        if let opened = leaseStore.openedLogin(for: lease.requestID) {
            secret = opened
        } else if lease.automatic {
            let keys = try macKeys()
            guard let login = leaseLogins.first(where: { $0.id.uuidString == lease.loginID }) else {
                throw AgentRPCError(.notFound, "The selected login is no longer available.")
            }
            guard let copy = try await store.sealed()
                .filter({ $0.loginID == lease.loginID && $0.openerID == keys.machineID })
                .max(by: { $0.version < $1.version }) else {
                throw AgentRPCError(.permissionDenied, "This login is not ready for Automatic use on this Mac yet. Ask again, or confirm Automatic copies in Agent Keyring.")
            }
            try keys.check(copy, members: device?.members)
            let opened = try CredentialSealing.openSealedLogin(copy, with: keys.receiving)
            try checkShown(opened, as: login)
            secret = opened
        } else {
            throw AgentRPCError(.permissionDenied, "Agent Keyring restarted since this was approved. Ask again.")
        }
        var values = Agentkeyring_V2_CredentialValues()
        for field in fields {
            switch field {
            case .username:
                guard !secret.username.isEmpty else { throw AgentRPCError(.invalidArgument, "The login has no account name.") }
                values.username = secret.username
            case .password:
                guard !secret.password.isEmpty else { throw AgentRPCError(.invalidArgument, "The login has no single password.") }
                values.password = secret.password
            case .oneTimeCode:
                let now = Int64(Date().timeIntervalSince1970)
                if let codes = leaseStore.openedCodes(for: lease.requestID) {
                    guard let code = codes.first(where: { $0.validFromUnixSeconds <= now && now < $0.validUntilUnixSeconds }) else {
                        throw AgentRPCError(.invalidArgument, "The login has no one-time code for now.")
                    }
                    values.oneTimeCode = code.code
                    continue
                }
                guard !secret.totpSeed.isEmpty, let code = try OneTimeCodes.codes(for: secret, from: now, until: now + 1).first else {
                    throw AgentRPCError(.invalidArgument, "The login has no one-time code.")
                }
                values.oneTimeCode = code.code
            default: break
            }
        }
        return values
    }
}
#endif
