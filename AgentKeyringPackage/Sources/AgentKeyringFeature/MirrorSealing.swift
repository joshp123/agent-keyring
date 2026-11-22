// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Each password sealed separately to each key that may open it: this Mac's
// chip key always; the receiving key of every enrolled computer (this Mac
// included) when its rule is Automatic; and the other approving devices.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MirrorAppModel {
    /// True when this Mac may hold local Automatic copies: either standalone (no Members yet)
    /// or still listed as a machine in the current signed Members list.
    var thisMacIsEnrolledMachine: Bool {
        guard let keys = try? macKeys() else { return false }
        guard let members = device?.members else { return true }
        return members.machines.contains { $0.machineID == keys.machineID }
    }

    /// A Blocked login has only this Mac's copy, so it can be unblocked here.
    /// `version` is when the secret was imported; every copy of it carries that.
    func sealCopies(of secret: Agentkeyring_V2_LoginSecret, version: UInt64, automatic: Bool, blocked: Bool = false) throws -> [Agentkeyring_V2_SealedLogin] {
        let keys = try macKeys()
        var openers: [(id: String, key: P256.KeyAgreement.PublicKey)] = [(keys.deviceKeyID, keys.openingPublicKey)]
        if automatic, thisMacIsEnrolledMachine { openers.append((keys.machineID, keys.receiving.publicKey)) }
        if !blocked { openers += device?.otherOpeners(automatic: automatic) ?? [] }
        return try openers.map { try Sealing.seal(secret, version: version, to: $0.key, openerID: $0.id, signer: keys.signer) }
    }

    /// The Mac's own copy of a login, sealed to its chip key (newest version, or a specific version if given).
    func macCopy(of loginID: String, version: UInt64? = nil) async throws -> Agentkeyring_V2_SealedLogin {
        let keys = try macKeys()
        let matches = try await store.sealed().filter {
            $0.loginID == loginID && $0.openerID == keys.deviceKeyID && (version == nil || $0.version == version)
        }
        guard let copy = matches.max(by: { $0.version < $1.version }) else {
            throw LeaseFailure(.notFound, "This Mac has no copy of this password. Copy your passwords again from Passwords.")
        }
        do { try keys.check(copy, members: device?.members) } catch {
            throw LeaseFailure(.permissionDenied, "This Mac's copy of this password was not sealed by one of your devices. Copy your passwords again from Passwords.")
        }
        return copy
    }

    /// An opened login only if it was sealed as the login shown for it: the
    /// list on disk is not trusted to say which password a request is for.
    func checkShown(_ secret: Agentkeyring_V2_LoginSecret, as login: CredentialCandidate) throws {
        do { try Sealing.checkBound(secret, title: login.title, sites: login.origins, account: login.username ?? "") } catch {
            throw LeaseFailure(.permissionDenied, "This password's details on this Mac don't match its sealed copy. Copy your passwords again from Passwords.")
        }
    }

    /// A rule change, after Josh's Touch ID: a password switched to Automatic
    /// is opened once and sealed to every enrolled computer (this Mac included);
    /// one switched away loses those copies. A password set to Blocked keeps
    /// only this Mac's copy; one unblocked is sealed to the other devices again.
    /// The other devices then get the new rules.
    func applyRuleChange(from old: [UUID: CredentialAccessPolicy], to new: [UUID: CredentialAccessPolicy], context: LAContext) async throws {
        let keys = try macKeys()
        let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        if changed.contains(where: { new[$0] == .allowAutomatically }) {
            try await device?.allowAutomaticOnAllMachines(context: context)
        }
        let machines = Set((thisMacIsEnrolledMachine ? [keys.machineID] : []) + (device?.members?.machines.map(\.machineID) ?? []))
        let blockedIDs = Set(changed.filter { new[$0] == .block }.map(\.uuidString))
        let automaticChangedIDs = Set(changed.filter { (old[$0] == .allowAutomatically) != (new[$0] == .allowAutomatically) }.map(\.uuidString))
        var added: [Agentkeyring_V2_SealedLogin] = []
        for id in changed where old[id] == .block {
            let copy = try await macCopy(of: id.uuidString)
            let secret = try keys.open(copy, context: context)
            added += try (device?.otherOpeners(automatic: false) ?? []).map {
                try Sealing.seal(secret, version: copy.version, to: $0.key, openerID: $0.id, signer: keys.signer)
            }
        }
        for id in changed where (old[id] == .allowAutomatically) != (new[id] == .allowAutomatically) && new[id] == .allowAutomatically {
            let loginID = id.uuidString
            let copy = try await macCopy(of: loginID)
            let secret = try keys.open(copy, context: context)
            added += try sealCopies(of: secret, version: copy.version, automatic: true).filter { machines.contains($0.openerID) }
        }
        let ownDeviceKeyID = keys.deviceKeyID
        let addedKeys = Set(added.map { $0.openerID + "/" + $0.loginID })
        let addedCopies = added
        try await store.updateSealed { current in
            var next = current
            next.removeAll { blockedIDs.contains($0.loginID) && $0.openerID != ownDeviceKeyID }
            next.removeAll { automaticChangedIDs.contains($0.loginID) && machines.contains($0.openerID) }
            next.removeAll { addedKeys.contains($0.openerID + "/" + $0.loginID) }
            return next + addedCopies
        }
        try await device?.publish(context: context)
        await noteMissingAutomaticCopies()
    }

    /// A rule change from the iPhone, which sends only the signed catalogue: its
    /// rules here, and every computer's copies of a password no longer
    /// Automatic withdrawn. Copies for a password newly Automatic need this
    /// Mac's Touch ID to make (`automaticCopiesMissing`).
    func adoptCatalogue(_ catalogue: Agentkeyring_V2_Catalogue) async {
        guard let keys = try? macKeys() else { return }
        var next: [UUID: CredentialAccessPolicy] = [:]
        for login in catalogue.logins {
            guard let id = UUID(uuidString: login.loginID) else { continue }
            switch login.rule {
            case .automatic: next[id] = .allowAutomatically
            case .blocked: next[id] = .block
            default: break
            }
        }
        let automatic = Set(next.filter { $0.value == .allowAutomatically }.keys.map(\.uuidString))
        let blocked = Set(next.filter { $0.value == .block }.keys.map(\.uuidString))
        let currentMembers = device?.members
        let computers = Set((currentMembers?.machines ?? []).map(\.machineID))
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let ownMachineID = keys.machineID
        let ownDeviceKeyID = keys.deviceKeyID
        let replyKeyID = keys.replyKeyID
        let replyPublicKey = keys.replyPublicKey
        accessControl.adopt(next)
        _ = try? await store.updateSealed { current in
            current.filter { copy in
                if copy.openerID != ownDeviceKeyID && blocked.contains(copy.loginID) { return false }
                if computers.contains(copy.openerID) && !automatic.contains(copy.loginID) { return false }
                if copy.openerID == ownMachineID {
                    guard automatic.contains(copy.loginID), let login = listed[copy.loginID],
                          login.loginID == copy.loginID, login.version == copy.version else { return false }
                    if copy.signerKeyID == replyKeyID {
                        return (try? Sealing.checkSealed(copy, by: replyKeyID, publicKey: replyPublicKey)) != nil
                    } else if let currentMembers {
                        return (try? Sealing.checkSealed(copy, members: currentMembers, listed: login)) != nil
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
    /// lacks a current-version Automatic copy (or still has a legacy `automaticAllowed == false` flag).
    func noteMissingAutomaticCopies() async {
        let hasAutomatic = leaseLogins.contains { accessControl.policy(for: $0.id) == .allowAutomatically }
        guard let keys = try? macKeys() else {
            localAutomaticCopyIDs = []
            try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
            automaticCopiesMissing = false
            return
        }
        let sealed: [Agentkeyring_V2_SealedLogin]
        do {
            sealed = try await store.sealed()
        } catch {
            DiagnosticLog.record("copies", "read-failed", ["reason": "\(error)"])
            localAutomaticCopyIDs = []
            try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
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
                guard accessControl.policy(for: login.id) == .allowAutomatically,
                      let expected = macVersions[loginID],
                      hasValidCopy(loginID: loginID, openerID: keys.machineID, version: expected, in: sealed, keys: keys) else { return nil }
                return loginID
            })
        } else {
            localAutomaticCopyIDs = []
        }
        automaticCopiesChecked = true
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        let legacyDisabled = hasAutomatic && (device?.members?.machines.contains { !$0.automaticAllowed } == true)
        automaticCopiesMissing = !(await missingAutomaticCopies(sealed: sealed)).isEmpty || legacyDisabled
        let previousPending = pendingAutomaticCatalogueLoginIDs
        pendingAutomaticCatalogueLoginIDs = pendingAutomaticCatalogueLogins(sealed: sealed, keys: keys)
        if !pendingAutomaticCatalogueLoginIDs.isEmpty && pendingAutomaticCatalogueLoginIDs != previousPending {
            askToSendChanges()
        }
    }

    /// Automatic login IDs where an earlier build discarded the Mac's chip-key copy of the signed catalogue version
    /// during a pending import, leaving another enrolled computer without an Automatic copy until Send Changes runs.
    private func pendingAutomaticCatalogueLogins(sealed: [Agentkeyring_V2_SealedLogin], keys: MacKeys) -> Set<String> {
        let otherReceivers = (device?.otherOpeners(automatic: true) ?? []).filter { opener in
            device?.members?.machines.contains { $0.machineID == opener.id } == true
        }
        guard !otherReceivers.isEmpty else { return [] }
        let macCopiesByLogin = Dictionary(grouping: sealed.filter { $0.openerID == keys.deviceKeyID }, by: \.loginID)
        let signedVersions = Dictionary(
            (device?.catalogue?.logins ?? []).map { ($0.loginID, $0.version) },
            uniquingKeysWith: { first, _ in first }
        )
        var pending: Set<String> = []
        for login in leaseLogins where accessControl.policy(for: login.id) == .allowAutomatically {
            let loginID = login.id.uuidString
            let availableVersions = Set((macCopiesByLogin[loginID] ?? []).map(\.version))
            guard let newestVersion = availableVersions.max(),
                  let signedVersion = signedVersions[loginID],
                  newestVersion > signedVersion,
                  !availableVersions.contains(signedVersion) else { continue }
            if otherReceivers.contains(where: { !hasValidCopy(loginID: loginID, openerID: $0.id, version: signedVersion, in: sealed, keys: keys) }) {
                pending.insert(loginID)
            }
        }
        return pending
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
        for login in leaseLogins where accessControl.policy(for: login.id) == .allowAutomatically {
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
        try await device?.allowAutomaticOnAllMachines(context: context)
        let startMembersRevision = device?.members?.revision
        let startWasEnrolled = thisMacIsEnrolledMachine
        let targets = await missingAutomaticCopies()
        var added: [Agentkeyring_V2_SealedLogin] = []
        for target in targets {
            let copy = try await macCopy(of: target.loginID, version: target.version)
            let secret = try keys.open(copy, context: context)
            added += try target.receivers.map { try Sealing.seal(secret, version: copy.version, to: $0.key, openerID: $0.id, signer: keys.signer) }
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
        return leaseLogins.map { login in
            var item = Agentkeyring_V2_Login()
            item.loginID = login.id.uuidString
            item.title = login.title
            item.sites = login.origins
            item.account = login.username ?? ""
            item.hasOneTimeCode_p = login.availableFields.contains(.totp)
            item.rule = switch accessControl.policy(for: login.id) {
            case .ask: .ask
            case .allowAutomatically: .automatic
            case .block: .blocked
            }
            item.version = versions[login.id.uuidString] ?? 0
            return item
        }
    }

    /// The values a local lease delivers: from the login opened at approval,
    /// or for an Automatic lease from the Mac's copy sealed to its receiving key.
    func values(for lease: Agentkeyring_V1_Lease, fields: [Agentkeyring_V1_CredentialField]) async throws -> Agentkeyring_V1_CredentialValues {
        guard lease.state == .active else {
            throw LeaseFailure(.permissionDenied, "The lease is not active. Inspect its status before starting another request.")
        }
        let secret: Agentkeyring_V2_LoginSecret
        if let opened = leaseStore.openedLogin(for: lease.leaseID) {
            secret = opened
        } else if leaseStore.isAutomatic(lease.leaseID) {
            let keys = try macKeys()
            guard let login = leaseLogins.first(where: { $0.id.uuidString == lease.loginID }) else {
                throw LeaseFailure(.notFound, "The selected login is no longer available.")
            }
            guard let copy = try await store.sealed()
                .filter({ $0.loginID == lease.loginID && $0.openerID == keys.machineID })
                .max(by: { $0.version < $1.version }) else {
                throw LeaseFailure(.permissionDenied, "This login is not ready for Automatic use on this Mac yet. Ask again, or confirm Automatic copies in Agent Keyring.")
            }
            try keys.check(copy, members: device?.members)
            let opened = try Sealing.open(copy, with: keys.receiving)
            try checkShown(opened, as: login)
            secret = opened
        } else {
            throw LeaseFailure(.permissionDenied, "Agent Keyring restarted since this was approved. Ask again.")
        }
        var values = Agentkeyring_V1_CredentialValues()
        for field in fields {
            switch field {
            case .username:
                guard !secret.username.isEmpty else { throw LeaseFailure(.invalidArgument, "The login has no account name.") }
                values.username = secret.username
            case .password:
                guard !secret.password.isEmpty else { throw LeaseFailure(.invalidArgument, "The login has no single password.") }
                values.password = secret.password
            case .oneTimeCode:
                let now = Int64(Date().timeIntervalSince1970)
                if let codes = leaseStore.openedCodes(for: lease.leaseID) {
                    guard let code = codes.first(where: { $0.validFromUnixSeconds <= now && now < $0.validUntilUnixSeconds }) else {
                        throw LeaseFailure(.invalidArgument, "The login has no one-time code for now.")
                    }
                    values.oneTimeCode = code.code
                    continue
                }
                guard !secret.totpSeed.isEmpty, let code = try OneTimeCodes.codes(for: secret, from: now, until: now + 1).first else {
                    throw LeaseFailure(.invalidArgument, "The login has no one-time code.")
                }
                values.oneTimeCode = code.code
            default: break
            }
        }
        return values
    }
}
