// Written by AI on 2026.11.23 by model claude opus 5.5; edited on 2026.11.28 by model claude opus 5.5.
//
// This Mac and the user's other Apple devices through his own iCloud private
// database, the same way an iPhone does it (AgentKeyringEngine/Cloud,
// CloudReplicaSyncCoordinator). What is the Mac's own: its lists in one
// keychain item, every sealed copy in MacVaultFileStore, other devices' vaults
// folded into its own list by the app, and an iPhone's or Mac's join shown
// once it proves the invitation this Mac left. Pushes to this Mac: CloudKit's
// when anything changes, and a computer's request notice, opened with this
// Mac's notice key and shown in the panel (takeRemoteAsk).

#if os(macOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation

@MainActor
extension MacSyncCoordinator: CloudReplicaHost {
    /// Opaque, container-scoped CloudKit user identifier for anonymous daily update checks.
    public static func cloudAccountSeed() async -> String? {
        await CloudVault()?.fetchCloudUserRecordName()
    }

    /// Whether this Mac's lists are in iCloud, as Settings shows it.
    public var cloudState: CloudSyncState { cloudSync.state }

    /// Something in iCloud changed, or the app started: fetch what changed, one fetch at a time.
    public func cloudChanged() { cloudSync.pullCloudSoon() }

    // MARK: The Mac as a replica

    package var replica: MacSavedLists { saved }
    package var replicaReadable: Bool { !savedListsLocked }
    package var replicaDeviceID: String? { keys.deviceKeyID }
    package var replicaSigningPublicKey: Data? { keys.signingPublicKey.x963Representation }
    package var replicaMachineID: String? { keys.machineID }
    package var replicaKeyOpener: CloudEnvelope.KeyOpener? { keys.cloudKeyOpener }
    package var replicaReplySigner: PayloadReplySigner { keys.signer }
    package var replicaLog: KeyringDiagnosticLog { .mac }

    package func receivePeerVault(_ vault: CredentialVault) async -> Bool { await onPeerVault?(vault) ?? true }

    /// The Mac keeps every copy sealed to a device or computer in the list: it serves them, and seals again from them.
    package func takesCloudCopies(for recipient: String) -> Bool { true }

    package func receiveCheckedCloudCopies(_ copies: [SealedLogin], for recipient: String) async -> CloudCopiesIntake {
        var batch = Agentkeyring_V2_SealedLogins()
        batch.logins = copies
        guard let payload = try? batch.serializedData(), await receiveSealedCopies(payload) else { return .notSaved }
        return .kept
    }

    /// A join waiting for Touch ID is fetched again on every pull, so a relaunch shows it again; one this launch
    /// already holds is taken again only when its record changed, so an expired one stays ended.
    package func receiveCloudJoins(from pull: ReplicaPull) async {
        let changed = Set(pull.changes.records.map(\.name))
        for record in pull.peerRecords("join-", notBy: keys.deviceKeyID) {
            if changed.contains(record.name) || joinRecords[record.writer] == nil { await takeCloudJoin(record) }
            if joinWaits(record.writer) { pull.markRecordForRetry(record.name) } else { pull.clearRecordRetry(record.name) }
        }
    }

    package func cloudSealedRecordsTaken() async { await onAutomaticCopiesChanged?() }

    package func cloudPullFinished(peerChanges: Int) {
        if peerChanges > 0 { KeyringDiagnosticLog.mac.noteDeviceEvent("cloud", "pulled", ["records": "\(peerChanges)"]) }
    }

    package func ownCloudVault() async -> CredentialVault? { await ownVault?() }

    package func pushRegistrationsWrittenHere(in members: Members) -> [String] { [keys.deviceKeyID] }

    /// The copies this Mac sealed for each other device, and each other computer's of its Automatic passwords, of
    /// the versions the signed catalogue lists.
    package func cloudCopiesToShare(in members: Members) async throws -> [(recipient: String, copies: [SealedLogin])] {
        let listed = Dictionary((catalogue?.logins ?? []).map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let sealed = try await store.sealed()
        let devices = members.devices.filter { $0.keyID != keys.deviceKeyID }.map { ($0.keyID, false) }
        let machines = members.machines.filter { $0.machineID != keys.machineID }.map { ($0.machineID, true) }
        return (devices + machines).map { recipient, automaticOnly in
            (recipient, sealed.filter { copy in
                copy.openerID == recipient && copy.signerKeyID == keys.replyKeyID
                    && listed[copy.loginID].map { $0.holdsSecret && $0.version == copy.version && (!automaticOnly || $0.rule == .automatic) } == true
            })
        }
    }

    /// A join through iCloud is done once its device is in the list, or once it was refused or ran out: the
    /// joiner reads its request gone as not added.
    package func endedCloudJoinNames(in members: Members) -> [String] {
        let ended = joinHistory.filter { $0.state != .waiting && $0.state != .approved }.map(\.id)
        return (members.devices.map(\.keyID) + members.machines.map(\.machineID) + ended).map(CloudRecordKind.join)
    }

    package func mailboxSlotWrite() async -> MailboxSlotWrite? {
        MailboxSlotWrite(copies: (try? await store.sealed()) ?? [], deviceID: keys.deviceKeyID, signer: keys.signer,
                         catalogueRevision: catalogue?.revision ?? 0, relay: environment.relay)
    }

    package func cloudSyncStateChanged(from previous: CloudSyncState) {
        if cloudState == .syncing { leaveInvitation() }
    }

    // MARK: Joining through iCloud

    /// An iPhone asking to join through iCloud: shown if it proves an invitation this Mac left in iCloud Keychain. A Mac asking to join an iPhone's list is the iPhone's to answer. Its Touch ID approval publishes the new
    /// Members and seals its copies, which it then takes from iCloud.
    private func takeCloudJoin(_ record: CloudRecord) async {
        // A new Mac asks twice: as a device, and as the computer its agents run on. The computer's request
        // waits here, proving the same invitation, to be added with the device's one Touch ID.
        if let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: record.payload), case let .machine(machine)? = request.joining {
            invitations = invitations.filter { $0.value > .now }
            guard machine.machineID == CredentialSealing.keyID(machine.tlsPublicKey),
                  invitations.keys.contains(where: { CredentialSealing.joinProof(secret: $0, joining: request) == request.proof }) else { return }
            cloudMachineJoins[record.writer] = machine
            if joinRecords[record.writer]?.state == .waiting {
                joinSignal.fire()
            }
            return
        }
        guard let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: record.payload),
              case let .device(device)? = request.joining, device.kind == .iphone || device.kind == .mac, device.keyID == record.writer,
              device.keyID == CredentialSealing.keyID(device.signingPublicKey),
              (try? P256.KeyAgreement.PublicKey(x963Representation: device.openingPublicKey)) != nil,
              (try? P256.KeyAgreement.PublicKey(x963Representation: device.noticePublicKey)) != nil else { return }
        let id = device.keyID
        if members?.devices.contains(where: { $0.keyID == id && $0.openingPublicKey == device.openingPublicKey }) == true {
            try? await cloudSync.cloud?.deleteCloudRecords([record.name])
            return
        }
        if let existing = joinRecords[id], existing.request == request, existing.state != .expired { return }
        invitations = invitations.filter { $0.value > .now }
        guard let secret = invitations.keys.first(where: { CredentialSealing.joinProof(secret: $0, joining: request) == request.proof }) else {
            KeyringDiagnosticLog.mac.noteDeviceEvent("join", "cloud-refused", ["reason": "proves no invitation this Mac holds"])
            return
        }
        joinRecords[id] = HeardJoinRequest(request: request, secret: secret, asked: .now, state: .waiting)
        KeyringDiagnosticLog.mac.noteDeviceEvent("join", "asked", ["joiner": String(id.prefix(16)), "route": "icloud"])
        joinSignal.fire()
    }

    /// A join through iCloud still waiting for Touch ID here: the device's own, or a new Mac's computer one
    /// whose device has not asked yet.
    private func joinWaits(_ writer: String) -> Bool {
        if let join = joinRecords[writer] { return join.state == .waiting }
        return cloudMachineJoins[writer] != nil
    }

    // MARK: This Mac's push address

    /// Apple gave this Mac a push address: signed with its reply key, kept and shared like a device's, so a
    /// computer's requests reach it. The newest wins.
    public func registerPush(token: Data, topic: String, production: Bool) {
        var registration = Agentkeyring_V2_PushRegistration()
        registration.domain = "agentkeyring.push.v2"
        registration.deviceKeyID = keys.deviceKeyID
        registration.apnsToken = token
        registration.apnsTopic = topic
        registration.apnsProduction = production
        registration.noticePublicKey = keys.notice.publicKey.x963Representation
        // Strictly after the one it replaces, so a second token in the same second still wins on every device.
        let previous = self.registration(for: keys.deviceKeyID)?.registeredUnixSeconds ?? 0
        registration.registeredUnixSeconds = max(Int64(Date.now.timeIntervalSince1970), previous + 1)
        guard let signed = try? CredentialSealing.signedDocument(registration.serializedData(), by: keys.replyKeyID, sign: keys.signReply),
              let bytes = try? signed.serializedData() else { return }
        if let current = self.registration(for: keys.deviceKeyID), current.apnsToken == token, current.apnsProduction == production,
           current.noticePublicKey == registration.noticePublicKey { return }
        saved.pushRegistrations[keys.deviceKeyID] = bytes
        persist()
        cloudSync.pushCloudSoon()
        KeyringDiagnosticLog.mac.noteDeviceEvent("push", "registered", ["device": keys.label, "production": "\(production)"])
    }

    /// A push to this Mac: CloudKit's, or a computer's request notice, opened with this Mac's notice key.
    /// A waiting request is shown in the panel; an outcome closes it.
    public func receivedPush(_ userInfo: [AnyHashable: Any]) {
        if CloudVault.isCloudNotification(userInfo) { return cloudChanged() }
        guard let base64 = userInfo["akr"] as? String, let bytes = Data(base64Encoded: base64),
              let notice = try? Agentkeyring_V2_Notice(serializedBytes: bytes),
              let envelope = try? CredentialSealing.openNotice(notice, deviceKeyID: keys.deviceKeyID, with: keys.notice),
              let members, let request = try? CredentialSealing.parseRequest(envelope.request) else { return }
        // A practice request another device made for this Mac: shown here like this Mac's own, answered in its box.
        if request.domain == CredentialSealing.practiceRequestDomain {
            guard !envelope.hasOutcome else { return }
            do {
                guard try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keys.deviceKeyID) == nil else { return }
            } catch {
                KeyringDiagnosticLog.mac.noteDeviceEvent("practice", "refused", ["request": request.requestID, "reason": "\(error)"])
                return
            }
            devicePractice = envelope
            KeyringDiagnosticLog.mac.noteDeviceEvent("practice", "from-device", ["request": request.requestID])
            onPracticeHere?()
            return
        }
        guard (try? CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keys.deviceKeyID)) != nil else { return }
        // An outcome closes only the request shown, by its exact bytes, which only the asking computer and
        // the devices it pushed to hold.
        if envelope.hasOutcome {
            guard remoteAsks[request.requestID]?.signed.payload == envelope.request, envelope.outcome.requestID == request.requestID else { return }
            return endRemote(request.requestID, envelope.outcome)
        }
        if case let .refused(reason) = takeRemoteAsk(envelope) {
            KeyringDiagnosticLog.mac.noteDeviceEvent("remote", "not-shown", ["request": request.requestID, "reason": reason])
        }
    }
}
#endif
