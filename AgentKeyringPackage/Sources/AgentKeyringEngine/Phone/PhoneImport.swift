// Written by AI on 2026.11.23 by model claude opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Copying from Passwords on this iPhone: merged into its vault, sealed for every device and computer,
// signed after one Face ID, and the reminder to copy again.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
#if os(iOS)
import AuthenticationServices
#endif
import CryptoKit
import Foundation
import LocalAuthentication
import UserNotifications

@MainActor
extension PhoneKeyringEngine {
    // MARK: Copying from Passwords, on this iPhone

    var passwordsCopyFacts: PhonePasswordsCopy {
        var facts = passwordsCopy
        let fromCatalogue = (catalogue?.importedUnixSeconds).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        // The catalogue's time is when it was last signed, a rule change included: only a stand-in, with no vault yet.
        facts.copiedAt = state.copiedAt ?? fromCatalogue
        facts.isStale = facts.copiedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? false
        return facts
    }

    static let staleAfter: TimeInterval = 7 * 86_400

    /// Reads again whether Agent Keyring is on in Passwords, and sets the reminder from the newest copy.
    func refreshPasswordsCopy() {
        Task { _ = await turnOnInPasswords(asking: false) }
        scheduleReminder()
    }

    public func turnOnInPasswords(asking: Bool) async -> Bool {
        #if os(iOS)
        var on = await ASCredentialIdentityStore.shared.state().isEnabled
        if !on, asking { on = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension() }
        passwordsCopy.turnedOn = on
        return on
        #else
        return false
        #endif
    }

    /// An export from Passwords on this iPhone: merged into this iPhone's vault like any device's, each
    /// login's secret sealed to this iPhone, to every other device, and, for an Automatic one, to every
    /// computer, then the new catalogue signed after one Face ID. A Blocked login's secret is not kept.
    public func receiveImport(token: UUID) async {
        guard state.deviceKeyID != nil, !passwordsCopy.copying, handledImportTokens.insert(token).inserted else { return }
        passwordsCopy.copying = true
        passwordsCopy.problem = nil
        defer { passwordsCopy.copying = false }
        do {
            #if os(iOS)
            let data = try await SystemCredentialImporter().importCredentials(token: token)
            let batch = CredentialExchangeMapper().map(data, scope: .selected)
            guard !batch.items.isEmpty else {
                let onlyPasskeys = (batch.skippedCredentialSummary?.passkeyCount ?? 0) > 0
                passwordsCopy.problem = onlyPasskeys ? MessageCopy.exportOnlyPasskeys : PhoneCopy.copyFailed
                return
            }
            #else
            let batch = LoginImportBatch(scope: .selected, exportedAt: .now, exporterIdentifier: "", exporterDisplayName: "", items: [], skippedCredentialCount: 0)
            #endif
            _ = await refresh()
            let context = LAContext()
            defer { context.invalidate() }
            try await keys.authorize(context, reason: PhoneCopy.faceIDSaveCopy)
            // Twice at most: if another device changed the list meanwhile, it is merged in and signed again.
            for attempt in 0..<2 {
                do { return try await saveImport(batch, context: context) }
                catch PhoneApprovalError.notAllowed(_) where attempt == 0 { _ = await refresh() }
            }
        } catch is CancellationError {
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("copy", "failed", ["error": "\(error)"])
            if (error as? LAError)?.code != .userCancel { passwordsCopy.problem = PhoneCopy.copyFailed }
        }
    }

    private func saveImport(_ batch: LoginImportBatch, context: LAContext) async throws {
        guard let me = state.deviceKeyID, let members else { throw PhoneApprovalError.notJoined }
        let previous = catalogue
        // What the import starts from: another device's catalogue taken meanwhile, even one of the same
        // revision (a Block made apart), means it is merged in and signed again.
        let started = (state.catalogue, state.contestedCatalogues, state.members, state.ownVaultSnapshot)
        let unchanged = { [self] in started == (state.catalogue, state.contestedCatalogues, state.members, state.ownVaultSnapshot) }
        let merged = try VaultSnapshotMerger().mergeImportedSnapshot(previous: ownVaultSnapshot, importBatch: batch, rules: previous?.rules ?? [:], actor: me)
        let own = try P256.KeyAgreement.PublicKey(x963Representation: keys.openingPublicKey())
        let devices = members.devices.filter { $0.keyID != me }.compactMap { device in
            (try? P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)).map { (device.keyID, $0) }
        }
        let computers = members.machines.compactMap { machine in
            (try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)).map { (machine.machineID, $0) }
        }
        // Sealed away from the main thread, with the reply key loaded once: hundreds of passwords, each to
        // several devices, take a while.
        let secrets = merged.snapshot.items.filter { merged.sealing.contains($0.id) }
            .map { (secret: $0.secret, automatic: merged.rules[$0.id]?.rule == .automatic) }
        let sign = try keys.replySigner()
        let replyKeyID = CredentialSealing.keyID(try keys.replyPublicKey())
        let version = merged.version
        let (mine, others) = try await Task.detached { () throws -> ([SealedLogin], [SealedLogin]) in
            let signer = PayloadReplySigner(keyID: replyKeyID, sign: sign)
            var mine: [SealedLogin] = [], others: [SealedLogin] = []
            for (secret, automatic) in secrets {
                mine.append(try CredentialSealing.sealLogin(secret, version: version, to: own, openerID: me, signer: signer))
                for (id, key) in devices + (automatic ? computers : []) {
                    others.append(try CredentialSealing.sealLogin(secret, version: version, to: key, openerID: id, signer: signer))
                }
            }
            return (mine, others)
        }.value
        guard unchanged() else { throw PhoneApprovalError.notAllowed("Another device changed the list while saving.") }
        var next = Catalogue()
        next.domain = "agentkeyring.catalogue.v2"
        next.revision = (previous?.revision ?? 0) + 1
        next.importedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let fresh = Dictionary(merged.sealing.map { ($0.uuidString, merged.version) }, uniquingKeysWith: { first, _ in first })
        next.logins = merged.snapshot.redacted.vault.catalogueLogins(rules: merged.rules, fresh: fresh, previous: previous)
        // A login another device listed that this iPhone has not seen yet stays listed.
        let ids = Set(next.logins.map(\.loginID))
        let gone = Set((merged.snapshot.deleted ?? [:]).keys.map(\.uuidString))
        next.logins += (previous?.logins ?? []).filter { !ids.contains($0.loginID) && !gone.contains($0.loginID) }
        let signed = try CredentialSealing.signedDocument(next.serializedData(), by: CredentialSealing.keyID(keys.signingPublicKey())) { try keys.signWithDeviceKey($0, context: context) }
        try keepOwnSealedCopies(mine, against: next)
        keepMadeForOthers(others, against: next)
        let machineIDs = Set(members.machines.map(\.machineID))
        let machineCopies = others.filter { machineIDs.contains($0.openerID) }
        if !machineCopies.isEmpty {
            await uploadMachineCopies(machineCopies, catalogue: next)
            guard unchanged() else { throw PhoneApprovalError.notAllowed("Another device changed the list while saving.") }
        }
        try await share(catalogue: signed)
        var saved = state
        saved.copiedAt = .now
        guard save(saved) else {
            throw PhoneApprovalError.notAllowed("Couldn't save the imported passwords on this iPhone.")
        }
        saveOwnVaultSnapshot(merged.snapshot)
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("copy", "saved", ["passwords": "\(next.logins.count)", "sealed": "\(mine.count)"])
        onListsChanged?()
        if firstRun == .importPasswords { apply(.passwordsImported) }
        scheduleReminder()
    }

    /// Seals Automatic logins to every enrolled computer from this iPhone's own copies, using the same Face ID.
    func sealAutomaticCopies(_ loginIDs: [String], context: LAContext) throws -> [SealedLogin] {
        guard let members else { return [] }
        let copies = ownCopies
        let targets = loginIDs.compactMap { copies[$0] }
        guard !targets.isEmpty else { return [] }
        let machines: [(id: String, key: P256.KeyAgreement.PublicKey)] = members.machines.compactMap { machine in
            guard let key = try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey) else { return nil }
            return (machine.machineID, key)
        }
        guard !machines.isEmpty else { return [] }
        var sealed: [SealedLogin] = []
        sealed.reserveCapacity(targets.count * machines.count)
        for copy in targets {
            let secret = try keys.openSealedLogin(copy, context: context)
            for (machineID, key) in machines {
                sealed.append(try CredentialSealing.sealLogin(secret, version: copy.version, to: key, openerID: machineID, signer: sealSigner))
            }
        }
        return sealed
    }

    /// Uploads newly sealed computer Automatic copies to iCloud immediately (merged with any existing
    /// Automatic copies for each computer) before publishing the new Catalogue revision.
    func uploadMachineCopies(_ fresh: [SealedLogin], catalogue targetCatalogue: Catalogue? = nil) async {
        guard let cloud = cloudSync.cloud, let me = state.deviceKeyID, let members, !fresh.isEmpty else { return }
        guard await cloud.availability() == .available, await cloudSync.confirmCloudMembers() == .owned else { return }
        let raw = state.sealedForOthers.flatMap { try? Agentkeyring_V2_SealedLogins(serializedBytes: $0) }?.logins ?? []
        let existing = Self.current(raw, catalogue: targetCatalogue ?? catalogue, members: members)
        let freshByOpener = Dictionary(grouping: fresh, by: \.openerID)
        var records: [CloudRecord] = []
        var stale: [String] = []
        do {
            let knownNames = state.cloudCheckpoint.knownNames
            for machine in members.machines {
                guard let added = freshByOpener[machine.machineID], !added.isEmpty else { continue }
                let replaced = Set(added.map(\.loginID))
                let combined = existing.filter { $0.openerID == machine.machineID && !replaced.contains($0.loginID) } + added
                let parts = try CloudCopies.records(combined, for: machine.machineID, writer: me)
                records += parts
                stale += CloudCopies.stale(knownNames, recipient: machine.machineID, writer: me, written: parts.count)
            }
            guard !records.isEmpty else { return }
            try await cloud.writeCloudRecords(records)
            updateReplica { $0.cloudCheckpoint.noteWritten(records.map(\.name)) }
            if !stale.isEmpty {
                try await cloud.deleteCloudRecords(stale)
                updateReplica { $0.cloudCheckpoint.noteDeleted(stale) }
            }
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("cloud", "machine copies not pre-uploaded", ["error": "\(error)"])
        }
    }

    // MARK: The reminder to copy again

    /// One notification once the newest copy from Passwords is a week old: set again at every copy and launch,
    /// so none comes for a week after one does. Off until he turns it on.
    func scheduleReminder() {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["copy-again"])
        guard state.remindToUpdate == true, let copied = passwordsCopyFacts.copiedAt else { return }
        let due = max(copied.addingTimeInterval(Self.staleAfter), Date().addingTimeInterval(3600))
        let content = UNMutableNotificationContent()
        content.title = MessageCopy.copyIsOld(days: max(7, Int(due.timeIntervalSince(copied) / 86_400)))
        content.body = PhoneCopy.reminderBody
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: due.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: "copy-again", content: content, trigger: trigger))
        #endif
    }
}
