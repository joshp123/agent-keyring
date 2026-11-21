// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Each password sealed separately to each key that may open it: this Mac's
// chip key always; the receiving key of each computer allowed Automatic
// passwords (this Mac included) when its rule is Automatic; and the other
// approving devices. No computer is allowed them until Josh sets a password
// to Automatic and approves the computers the rule bar names.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MirrorAppModel {
    /// A Blocked login has only this Mac's copy, so it can be unblocked here.
    /// `version` is when the secret was imported; every copy of it carries that.
    func sealCopies(of secret: Agentkeyring_V2_LoginSecret, version: UInt64, automatic: Bool, blocked: Bool = false) throws -> [Agentkeyring_V2_SealedLogin] {
        let keys = try macKeys()
        var openers: [(id: String, key: P256.KeyAgreement.PublicKey)] = [(keys.deviceKeyID, keys.openingPublicKey)]
        if automatic, automaticOnThisMac { openers.append((keys.machineID, keys.receiving.publicKey)) }
        if !blocked { openers += device?.otherOpeners(automatic: automatic) ?? [] }
        return try openers.map { try Sealing.seal(secret, version: version, to: $0.key, openerID: $0.id, signer: keys.signer) }
    }

    /// The Mac's own copy of a login, sealed to its chip key.
    func macCopy(of loginID: String) async throws -> Agentkeyring_V2_SealedLogin {
        let keys = try macKeys()
        guard let copy = try await store.sealed().first(where: { $0.loginID == loginID && $0.openerID == keys.deviceKeyID }) else {
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
    /// first switches on every computer not yet allowed Automatic passwords
    /// (the rule bar names them all), then is opened once and sealed to each;
    /// one switched away loses those copies. A password set to Blocked keeps
    /// only this Mac's copy; one unblocked is sealed to the other devices again.
    /// The other devices then get the new rules.
    func applyRuleChange(from old: [UUID: CredentialAccessPolicy], to new: [UUID: CredentialAccessPolicy], context: LAContext) async throws {
        let keys = try macKeys()
        let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        if changed.contains(where: { new[$0] == .allowAutomatically }) {
            let off = automaticComputers.filter { !$0.allowed }.map(\.id)
            if !off.isEmpty { try await setAutomatic(Dictionary(uniqueKeysWithValues: off.map { ($0, true) }), context: context) }
        }
        let machines = Set(automaticComputers.map(\.id))
        var sealed = try await store.sealed()
        var withdrawn = Set<String>()
        for id in changed where new[id] == .block {
            sealed.removeAll { $0.loginID == id.uuidString && $0.openerID != keys.deviceKeyID }
        }
        for id in changed where old[id] == .block {
            let copy = try await macCopy(of: id.uuidString)
            let secret = try keys.open(copy, context: context)
            sealed += try (device?.otherOpeners(automatic: false) ?? []).map {
                try Sealing.seal(secret, version: copy.version, to: $0.key, openerID: $0.id, signer: keys.signer)
            }
        }
        for id in changed where (old[id] == .allowAutomatically) != (new[id] == .allowAutomatically) {
            let loginID = id.uuidString
            sealed.removeAll { $0.loginID == loginID && machines.contains($0.openerID) }
            guard new[id] == .allowAutomatically else { withdrawn.insert(loginID); continue }
            let copy = try await macCopy(of: loginID)
            let secret = try keys.open(copy, context: context)
            sealed += try sealCopies(of: secret, version: copy.version, automatic: true).filter { machines.contains($0.openerID) }
        }
        try await store.replaceSealed(sealed)
        _ = withdrawn // The computers' copies are gone from the store above; the next bundle leaves them out.
        try await device?.publish(context: context)
    }

    static let automaticOnThisMacKey = "automaticOnThisMac"

    /// Whether agents on this Mac get Automatic passwords without asking.
    public var automaticOnThisMac: Bool {
        if let device, let own = device.members?.machines.first(where: { $0.machineID == device.ownMachineID }) {
            return own.automaticAllowed
        }
        return savedAutomaticOnThisMac
    }

    /// This Mac and every computer whose agents can ask, and whether each is
    /// allowed Automatic passwords.
    public var automaticComputers: [(id: String, allowed: Bool)] {
        guard let keys = try? macKeys() else { return [] }
        let others = (device?.members?.machines ?? []).filter { $0.machineID != keys.machineID }
        return [(keys.machineID, automaticOnThisMac)] + others.map { ($0.machineID, $0.automaticAllowed) }
    }

    /// Switches computers on or off for Automatic passwords, with a context
    /// Josh has just approved: each Automatic password is opened once and
    /// sealed to those switched on; those switched off lose their copies.
    public func setAutomatic(_ changes: [String: Bool], context: LAContext) async throws {
        let keys = try macKeys()
        try await device?.setAutomatic(changes, context: context)
        if let own = changes[keys.machineID] { savedAutomaticOnThisMac = own }
        var receivers: [(id: String, key: P256.KeyAgreement.PublicKey)] = []
        for (id, allowed) in changes where allowed {
            if id == keys.machineID { receivers.append((id, keys.receiving.publicKey)); continue }
            guard let machine = device?.members?.machines.first(where: { $0.machineID == id }) else { continue }
            receivers.append((id, try P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)))
        }
        var sealed = try await store.sealed().filter { changes[$0.openerID] == nil }
        if !receivers.isEmpty {
            for login in leaseLogins where accessControl.policy(for: login.id) == .allowAutomatically {
                let copy = try await macCopy(of: login.id.uuidString)
                let secret = try keys.open(copy, context: context)
                sealed += try receivers.map { try Sealing.seal(secret, version: copy.version, to: $0.key, openerID: $0.id, signer: keys.signer) }
            }
        }
        try await store.replaceSealed(sealed)
        device?.sendCopies(for: Set(changes.keys).subtracting([keys.machineID]))
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
    }

    /// A rule change from the iPhone, which sends only the signed catalogue: its
    /// rules here, and every computer's copies of a password no longer
    /// Automatic withdrawn. Copies for a password newly Automatic need this
    /// Mac's Touch ID to make (`automaticCopiesMissing`).
    func adoptCatalogue(_ catalogue: Agentkeyring_V2_Catalogue, ownCopies: [Agentkeyring_V2_SealedLogin]) async {
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
        if var sealed = try? await store.sealed() {
            sealed.removeAll { $0.openerID == keys.machineID }
            let blocked = Set(next.filter { $0.value == .block }.keys.map(\.uuidString))
            sealed.removeAll { $0.openerID != keys.deviceKeyID && blocked.contains($0.loginID) }
            let computers = Set((device?.members?.machines ?? []).map(\.machineID))
            sealed.removeAll { computers.contains($0.openerID) && !automatic.contains($0.loginID) }
            let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
            sealed += ownCopies.filter { automatic.contains($0.loginID) && (try? keys.check($0, members: device?.members, listed: listed[$0.loginID])) != nil }
            try? await store.replaceSealed(sealed)
        }
        accessControl.adopt(next)
        await noteMissingAutomaticCopies()
    }

    /// Whether a computer allowed Automatic passwords lacks a copy of one: a fact read from the copies, kept for the panel.
    func noteMissingAutomaticCopies() async {
        automaticCopiesMissing = !(await missingAutomaticCopies()).isEmpty
    }

    /// Each Automatic password, with the computers allowed Automatic passwords that have no copy of it.
    private func missingAutomaticCopies() async -> [String: [(id: String, key: P256.KeyAgreement.PublicKey)]] {
        guard let keys = try? macKeys(), let sealed = try? await store.sealed() else { return [:] }
        let receivers = (automaticOnThisMac ? [(id: keys.machineID, key: keys.receiving.publicKey)] : [])
            + (device?.otherOpeners(automatic: true) ?? []).filter { opener in device?.members?.machines.contains { $0.machineID == opener.id } == true }
        var missing: [String: [(id: String, key: P256.KeyAgreement.PublicKey)]] = [:]
        for login in leaseLogins where accessControl.policy(for: login.id) == .allowAutomatically {
            let lacking = receivers.filter { receiver in !sealed.contains { $0.loginID == login.id.uuidString && $0.openerID == receiver.id } }
            if !lacking.isEmpty { missing[login.id.uuidString] = lacking }
        }
        return missing
    }

    /// Makes the missing Automatic copies, with a context Josh has just approved: each password opened once.
    public func sealAutomaticCopies(context: LAContext) async throws {
        let keys = try macKeys()
        var sealed = try await store.sealed()
        for (loginID, receivers) in await missingAutomaticCopies() {
            let copy = try await macCopy(of: loginID)
            let secret = try keys.open(copy, context: context)
            sealed += try receivers.map { try Sealing.seal(secret, version: copy.version, to: $0.key, openerID: $0.id, signer: keys.signer) }
        }
        try await store.replaceSealed(sealed)
        device?.sendCopies(for: Set((device?.members?.machines ?? []).map(\.machineID)))
        await noteMissingAutomaticCopies()
    }

    /// The logins and their rules, as the other devices see them, each with
    /// the version of this Mac's own copy.
    func catalogueLogins() async throws -> [Agentkeyring_V2_Login] {
        let keys = try macKeys()
        let versions = Dictionary(try await store.sealed().filter { $0.openerID == keys.deviceKeyID }.map { ($0.loginID, $0.version) },
            uniquingKeysWith: { first, _ in first })
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
            guard let copy = try await store.sealed().first(where: { $0.loginID == lease.loginID && $0.openerID == keys.machineID }) else {
                throw LeaseFailure(.permissionDenied, "This login is not set up to be used without asking on this Mac. Ask Josh to set it to Automatic again, or to switch on Automatic passwords for this Mac in Devices.")
            }
            try keys.check(copy, members: device?.members)
            secret = try Sealing.open(copy, with: keys.receiving)
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
