// Written by AI on 2026.11.23 by model claude opus 5.5; split on 2026.11.27 by model claude opus 5.5.
//
// The iPhone as a vault of its own, the Mac's equal: it keeps its list beside
// the Mac's, can be set up with no Mac at all, and joins a Mac or another
// iPhone through iCloud. Copying from Passwords is in PhoneImport.swift,
// adding a computer in PhoneComputers.swift, and iCloud in PhoneCloud.swift.

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
    // MARK: This iPhone's own vault

    /// This iPhone's own vault: every login without its secret, other devices' folded in.
    var ownVaultSnapshot: StoredVaultSnapshot? {
        guard let data = state.ownVaultSnapshot else { return nil }
        do {
            return try StoredVaultSnapshot.decodeProtobuf(data)
        } catch {
            logger.error("Corrupt iPhone vault snapshot: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func saveOwnVaultSnapshot(_ snapshot: StoredVaultSnapshot) -> Bool {
        var next = state
        do {
            next.ownVaultSnapshot = try snapshot.redacted.encodeProtobuf()
        } catch {
            logger.error("Could not encode iPhone vault snapshot: \(String(describing: error), privacy: .public)")
            return false
        }
        // The newest copy from Passwords on any device, kept so the snapshot need not read the vault.
        let exported = snapshot.items.compactMap { $0.imports?.compactMap(\.exportedAt).max() }.max()
        next.copiedAt = [state.copiedAt, exported].compactMap { $0 }.max()
        guard save(next) else { return false }
        cloudSync.pushCloudSoon()
        return true
    }

    static let emptyVaultSnapshot = StoredVaultSnapshot(id: UUID(), previousSnapshotID: nil, createdAt: .now, sourceExportedAt: .distantPast,
        scope: .unknown, exporterIdentifier: "icloud", exporterDisplayName: "iCloud", items: [], skippedCredentialCount: 0)

    /// Copies this iPhone sealed for its other devices and computers, of the versions the catalogue lists;
    /// a computer's only of a password still Automatic.
    var madeForOthers: [SealedLogin] {
        let made = state.sealedForOthers.flatMap { try? Agentkeyring_V2_SealedLogins(serializedBytes: $0) }?.logins ?? []
        return Self.current(made, catalogue: catalogue, members: members)
    }

    /// The copies of `made` the catalogue and members still allow: current version of each password,
    /// for a listed device or computer, and for a computer only while the password is Automatic.
    nonisolated static func current(_ made: [SealedLogin], catalogue: Catalogue?, members: Members?) -> [SealedLogin] {
        let listed = Dictionary((catalogue?.logins ?? []).map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let devices = Set((members?.devices ?? []).map(\.keyID))
        let computers = Set((members?.machines ?? []).map(\.machineID))
        let openers = devices.union(computers)
        return made.filter { copy in
            guard openers.contains(copy.openerID),
                  let login = listed[copy.loginID], login.holdsSecret, login.version == copy.version else { return false }
            return !computers.contains(copy.openerID) || login.rule == .automatic
        }
    }

    /// New copies for other devices and computers, each in place of one for the same opener and password.
    func keepMadeForOthers(_ fresh: [SealedLogin], against targetCatalogue: Catalogue? = nil) {
        guard !fresh.isEmpty else { return }
        let replaced = Set(fresh.map { $0.openerID + "/" + $0.loginID })
        let raw = state.sealedForOthers.flatMap { try? Agentkeyring_V2_SealedLogins(serializedBytes: $0) }?.logins ?? []
        let existing = Self.current(raw, catalogue: targetCatalogue ?? catalogue, members: members)
        var all = Agentkeyring_V2_SealedLogins()
        all.logins = existing.filter { !replaced.contains($0.openerID + "/" + $0.loginID) } + fresh
        var next = state
        next.sealedForOthers = try? all.serializedData()
        save(next)
        let watchID = listedWatch?.keyID
        if fresh.contains(where: { $0.openerID == watchID }) { syncWatchCopiesSoon() }
        let machineIDs = Set((members?.machines ?? []).map(\.machineID))
        if fresh.contains(where: { machineIDs.contains($0.openerID) }) { cloudSync.mailboxes.writeMailboxSlotsSoon() }
        if fresh.contains(where: { $0.openerID != watchID }) { cloudSync.pushCloudSoon() }
    }

    /// This iPhone as a device in Members.
    func thisDevice() throws -> Agentkeyring_V2_Device {
        var device = Agentkeyring_V2_Device()
        device.kind = .iphone
        device.label = "iPhone"
        device.signingPublicKey = try keys.signingPublicKey()
        device.keyID = CredentialSealing.keyID(device.signingPublicKey)
        device.openingPublicKey = try keys.openingPublicKey()
        device.tlsPublicKey = try identity().publicKeySPKI
        device.replyPublicKey = try keys.replyPublicKey()
        device.replyKeyID = CredentialSealing.keyID(device.replyPublicKey)
        device.noticePublicKey = try keys.noticePublicKey()
        return device
    }

    // MARK: Set Up on This iPhone

    /// This iPhone keeps the passwords itself, with no Mac: its own Members, with only itself, and an empty
    /// catalogue, both signed after Face ID. If these keys already hold a list in iCloud (the app was removed
    /// and installed again), that list comes back instead. A list in iCloud that does not name this iPhone
    /// belongs to another device: this iPhone is added from there.
    public func setUpHere() async throws {
        guard state.deviceKeyID == nil else { return }
        let device = try thisDevice()
        if let cloud = cloudSync.cloud, await cloud.availability() == .available {
            if let held = try await cloud.fetchCloudPayload(named: CloudRecordKind.members) {
                return try restore(device, from: held)
            }
        }
        let context = LAContext()
        defer { context.invalidate() }
        try await keys.authorize(context, reason: PhoneCopy.faceIDSetUpHere)
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [device]
        var catalogue = Catalogue()
        catalogue.domain = "agentkeyring.catalogue.v2"
        catalogue.revision = 1
        catalogue.importedUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signedMembers = try CredentialSealing.signedDocument(members.serializedData(), by: device.keyID) { try keys.signWithDeviceKey($0, context: context) }
        let signedCatalogue = try CredentialSealing.signedDocument(catalogue.serializedData(), by: device.keyID) { try keys.signWithDeviceKey($0, context: context) }
        // One write: a crash between the device ID and its lists would leave a set-up iPhone that lists nothing.
        var next = state
        next.deviceKeyID = device.keyID
        next.adoptMembers(try CredentialSealing.verifySignedMembers(signedMembers, current: nil), signed: try signedMembers.serializedData())
        next.signCatalogue(try signedCatalogue.serializedData())
        guard save(next) else { throw PhoneApprovalError.notAllowed("Couldn't save this iPhone's set-up.") }
        onListsChanged?()
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("setup", "set up here", ["device": String(device.keyID.prefix(16))])
        looking?.cancel(); looking = nil
        apply(.setUpHere)
        cloudSync.pushCloudSoon()
        startBackgroundWork()
    }

    /// Takes back a list in iCloud from the first revision this iPhone signed itself that names it, each later
    /// one checked against the one before: a list this iPhone never signed is never taken on trust.
    private func restore(_ device: Agentkeyring_V2_Device, from payload: Data) throws {
        let revisions = CloudMembers.revisions(payload)
        guard let first = revisions.firstIndex(where: { $0.signerKeyID == device.keyID && Self.names(device, $0) }) else {
            throw PhoneSetUpFailure(PhoneCopy.alreadySetUpElsewhere)
        }
        try adopt(Array(revisions[first...]), as: device)
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("setup", "restored from iCloud", ["device": String(device.keyID.prefix(16))])
        looking?.cancel(); looking = nil
        apply(.setUpHere)
        startBackgroundWork()
    }

    /// A revision of Members that lists this device with exactly these keys.
    static func names(_ device: Agentkeyring_V2_Device, _ revision: SignedDocument) -> Bool {
        (try? Members(serializedBytes: revision.payload))?.devices.contains {
            $0.keyID == device.keyID && $0.signingPublicKey == device.signingPublicKey && $0.openingPublicKey == device.openingPublicKey
        } == true
    }

    /// Takes a list from iCloud, from `revisions[0]` (already chosen as the one to trust), each later one
    /// checked against the one before. The first is checked before anything here changes: one that does not
    /// verify leaves this iPhone as it was.
    private func adopt(_ revisions: [SignedDocument], as device: Agentkeyring_V2_Device) throws {
        guard let anchor = revisions.first else { throw CredentialSealingError.unknownSigner }
        _ = try CredentialSealing.verifySignedMembers(anchor, current: nil)
        let before = state
        var next = state
        next.deviceKeyID = device.keyID
        save(next)
        do { try receiveSignedMembers(anchor.serializedData()).requireTaken() } catch { save(before); throw error }
        for revision in revisions.dropFirst() { _ = (try? revision.serializedData()).map(receiveSignedMembers) }
        cloudSync.readWholeCloudNext()
    }

    // MARK: Joining a Mac through iCloud

    /// A Mac or another iPhone: the join request goes in iCloud, and this iPhone is added
    /// once a Members list there names it, the revision that added it signed by the device whose invitation it proved.
    func joinThroughCloud(_ card: Agentkeyring_V2_JoinInvite, generation: UInt64) async {
        guard let cloud = cloudSync.cloud, await cloud.availability() == .available else { return apply(.macUnreachable) }
        do {
            let request = try joinRequest(card)
            let me = request.device.keyID
            try await cloud.writeCloudRecords([CloudRecord(kind: CloudRecordKind.join(me), writer: me, payload: request.serializedData())])
            let asked = Date()
            while !Task.isCancelled, joiningGeneration == generation, firstRun.mayJoin {
                // The inviter takes the request away when it is refused, and also once it is added. Read before the
                // list, so a list written just before the request went is still seen.
                let gone = Date().timeIntervalSince(asked) > 15 ? try await cloud.fetchCloudPayload(named: CloudRecordKind.join(me)) == nil : false
                if let held = try await cloud.fetchCloudPayload(named: CloudRecordKind.members) {
                    let revisions = CloudMembers.revisions(held)
                    if let first = revisions.firstIndex(where: { Self.names(request.device, $0) }), revisions[first].signerKeyID == card.inviterKeyID {
                        try adopt(Array(revisions[first...]), as: request.device)
                        KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "joined through iCloud", ["device": String(me.prefix(16))])
                        looking?.cancel(); looking = nil
                        apply(.joined)
                        return startBackgroundWork()
                    }
                }
                if gone { return apply(.joinRefused) }
                if Date().timeIntervalSince(asked) > 600 { return apply(.joinExpired) }
                try await Task.sleep(for: .seconds(3))
            }
        } catch is CancellationError {
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "not asked through iCloud", ["error": "\(error)"])
            if joiningGeneration == generation, firstRun.mayJoin { apply(.macUnreachable) }
        }
    }
}
