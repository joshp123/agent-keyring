// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Each login sealed separately to each key that may open it: this Mac's chip
// key always; this Mac's receiving key, and each machine allowed Automatic
// logins, when its rule is Automatic; and the other approving devices.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MirrorAppModel {
    /// A login set to Ask on iPhone or Watch has no copy for this Mac at all.
    func sealCopies(of secret: Agentkeyring_V2_LoginSecret, automatic: Bool, phoneOnly: Bool = false) throws -> [Agentkeyring_V2_SealedLogin] {
        let keys = try macKeys()
        var openers: [(id: String, key: P256.KeyAgreement.PublicKey)] = phoneOnly ? [] : [(keys.deviceKeyID, keys.openingPublicKey)]
        if automatic { openers.append((keys.machineID, keys.receiving.publicKey)) }
        openers += device?.otherOpeners(automatic: automatic) ?? []
        return try openers.map { try Sealing.seal(secret, to: $0.key, openerID: $0.id) }
    }

    /// The example login is added at run time, never imported, so it is sealed here.
    func sealExampleIfNeeded() async throws {
        guard let example = generationIncludingExample(nil)?.items.first(where: \.isExample) else { return }
        let keys = try macKeys()
        let sealed = try await store.sealed()
        guard !sealed.contains(where: { $0.loginID == example.id.uuidString && $0.openerID == keys.deviceKeyID }) else { return }
        try await store.replaceSealed(sealed + sealCopies(of: example.secret,
            automatic: accessControl.policy(for: example.id) == .allowAutomatically))
    }

    /// The Mac's own copy of a login, sealed to its chip key.
    func macCopy(of loginID: String) async throws -> Agentkeyring_V2_SealedLogin {
        let keys = try macKeys()
        guard let copy = try await store.sealed().first(where: { $0.loginID == loginID && $0.openerID == keys.deviceKeyID }) else {
            throw LeaseFailure(.notFound, "This Mac has no sealed copy of the login. Import it again from Apple Passwords.")
        }
        return copy
    }

    /// A rule change, after Josh's Touch ID: a login switched to Automatic is
    /// opened once and sealed to the machines that may use it unasked; one
    /// switched away loses those copies. The other devices then get the new rules.
    func applyRuleChange(from old: [UUID: CredentialAccessPolicy], to new: [UUID: CredentialAccessPolicy], context: LAContext) async throws {
        let keys = try macKeys()
        let machines = Set([keys.machineID] + (device?.members?.machines.map(\.machineID) ?? []))
        var sealed = try await store.sealed()
        var withdrawn = Set<String>()
        for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
            if old[id] == .askOnPhone {
                throw LeaseFailure(.permissionDenied, "Change this login on your iPhone or Watch: only they can approve it.")
            }
            if new[id] == .askOnPhone, device?.members?.devices.contains(where: { $0.kind != .mac }) != true {
                throw LeaseFailure(.permissionDenied, "Add your iPhone first: until then nothing could approve this login.")
            }
            if new[id] == .askOnPhone { sealed.removeAll { $0.loginID == id.uuidString && $0.openerID == keys.deviceKeyID } }
        }
        for id in Set(old.keys).union(new.keys) where (old[id] == .allowAutomatically) != (new[id] == .allowAutomatically) {
            let loginID = id.uuidString
            sealed.removeAll { $0.loginID == loginID && machines.contains($0.openerID) }
            guard new[id] == .allowAutomatically else { withdrawn.insert(loginID); continue }
            let secret = try keys.open(try await macCopy(of: loginID), context: context)
            sealed += try sealCopies(of: secret, automatic: true).filter { machines.contains($0.openerID) }
        }
        try await store.replaceSealed(sealed)
        if device?.isJoined == true { try await device?.publish(context: context, withdrawn: withdrawn) }
    }

    /// A rule change from another device: its rules, and this Mac's Automatic
    /// copies exactly as that device left them at the relay.
    func adoptCatalogue(_ catalogue: Agentkeyring_V2_Catalogue, ownCopies: [Agentkeyring_V2_SealedLogin]) async {
        guard let keys = try? macKeys() else { return }
        var next: [UUID: CredentialAccessPolicy] = [:]
        for login in catalogue.logins {
            guard let id = UUID(uuidString: login.loginID) else { continue }
            switch login.rule {
            case .automatic: next[id] = .allowAutomatically
            case .blocked: next[id] = .block
            default: if login.phoneAndWatchOnly { next[id] = .askOnPhone }
            }
        }
        let automatic = Set(next.filter { $0.value == .allowAutomatically }.keys.map(\.uuidString))
        if var sealed = try? await store.sealed() {
            sealed.removeAll { $0.openerID == keys.machineID }
            let phoneOnly = Set(next.filter { $0.value == .askOnPhone }.keys.map(\.uuidString))
            sealed.removeAll { $0.openerID == keys.deviceKeyID && phoneOnly.contains($0.loginID) }
            sealed += ownCopies.filter { automatic.contains($0.loginID) }
            try? await store.replaceSealed(sealed)
        }
        accessControl.adopt(next)
    }

    /// The logins and their rules, as the other devices see them.
    func catalogueLogins() -> [Agentkeyring_V2_Login] {
        leaseLogins.map { login in
            var item = Agentkeyring_V2_Login()
            item.loginID = login.id.uuidString
            item.title = login.title
            item.sites = login.origins
            item.account = login.username ?? ""
            item.hasOneTimeCode_p = login.availableFields.contains(.totp)
            item.rule = switch accessControl.policy(for: login.id) {
            case .ask, .askOnPhone: .ask
            case .allowAutomatically: .automatic
            case .block: .blocked
            }
            item.phoneAndWatchOnly = accessControl.policy(for: login.id) == .askOnPhone
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
                throw LeaseFailure(.permissionDenied, "This login is not set up to be used without asking on this Mac. Ask Josh to set it to Automatic again.")
            }
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
