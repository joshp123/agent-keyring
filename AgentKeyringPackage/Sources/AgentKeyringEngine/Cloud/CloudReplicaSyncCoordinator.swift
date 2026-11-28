// Written by AI on 2026.11.28 by model claude opus 5.5.
//
// One way a Mac or an iPhone keeps its lists in step with the user's other devices through his iCloud private
// database. A pull takes what changed: Members first, each revision checked against the one before; then
// other devices' push addresses, the catalogue and any contested one, vaults, copies, requests to join and
// computers' mailboxes. Everything it takes is checked by its signatures, and its checkpoint moves only once
// everything it brought is saved. A push writes this device's side: Members and the catalogue only over an
// older revision, then push addresses, mailboxes, its vault, its side of a contest and the copies it sealed.
// What the two devices do differently is their CloudReplicaHost's.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Observation

@MainActor @Observable
package final class CloudReplicaSyncCoordinator<Host: CloudReplicaHost> {
    package private(set) var state = CloudSyncState.starting
    @ObservationIgnored package let cloud: (any CloudPipe)?
    @ObservationIgnored package let mailboxes: ComputerMailboxPublisher<Host>
    @ObservationIgnored package var sealCache = CloudSealCache()
    /// True while one pull takes its catalogues, vaults and copies, which only make sense together.
    @ObservationIgnored package internal(set) var takingSealedRecords = false
    /// Until when iCloud is read every few seconds: a device may be asking to join through it.
    @ObservationIgnored package var pollQuicklyUntil = Date.distantPast
    @ObservationIgnored weak var host: Host?
    @ObservationIgnored private var vaultDocument: (vault: CredentialVault, bytes: Data)?
    @ObservationIgnored private let pullGate = CloudPullGate()
    @ObservationIgnored private var pushing: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var readAllNext = false

    /// `cloud`: the user's iCloud private database; nil where there is none (tests, and a Mac given none).
    package init(cloud: (any CloudPipe)?) {
        self.cloud = cloud
        mailboxes = ComputerMailboxPublisher(cloud: cloud)
        mailboxes.sync = self
    }

    /// The device whose lists these are, once it is made.
    package func attachReplicaHost(_ host: Host) {
        self.host = host
        mailboxes.host = host
    }

    func moveSyncState(to next: CloudSyncState) {
        guard next != state else { return }
        let previous = state
        state = next
        // Signed out, computers are no longer held back for iCloud to accept the lists.
        if next == .signedOut { mailboxes.writeMailboxSlotsSoon() }
        host?.cloudSyncStateChanged(from: previous)
    }

    /// Lists iCloud has not accepted yet, or a contest: computers are sent no lists until both are settled.
    package var listsHeldFromComputers: Bool {
        guard let host else { return true }
        if host.replica.catalogueContested { return true }
        guard cloud != nil, state != .signedOut else { return false }
        return host.replica.cloudListsPending
    }

    /// Stops pulling, pushing and writing mailboxes.
    package func stopCloudSync() {
        stopCloudPolling()
        pushing?.cancel(); pushing = nil
        pullGate.cancelPulls()
        mailboxes.stopMailboxWrites()
    }

    /// Stops, and forgets what this launch knows of iCloud: on a reset, or when this device leaves the list.
    package func forgetRuntimeState() {
        stopCloudSync()
        sealCache = CloudSealCache()
        vaultDocument = nil
        mailboxes.forgetWrittenSlots()
        moveSyncState(to: .starting)
    }

    // MARK: Pulling

    /// Something in iCloud changed: one pull at a time, and once more if something changed while it ran.
    package func pullCloudSoon() {
        guard cloud != nil else { return }
        pullGate.trigger { [weak self] in await self?.pullCloudOnce() ?? false }
    }

    /// Pulls now, after any pull running, and says whether it was taken in.
    @discardableResult
    package func pullCloudNow() async -> Bool {
        guard cloud != nil else { return false }
        return await pullGate.runPull { [weak self] in await self?.pullCloudOnce() ?? false }
    }

    /// The next pull reads every record again, from no change token, even if this launch ends first.
    package func readWholeCloudNext() {
        readAllNext = true
        host?.updateReplica { $0.cloudCheckpoint.changeToken = nil }
    }

    /// CloudKit's pushes are a nudge Apple may hold back: iCloud is also read every `interval` seconds, and every
    /// five seconds until `pollQuicklyUntil`.
    package func startCloudPolling(every interval: TimeInterval) {
        guard cloud != nil, polling == nil else { return }
        polling = Task { [weak self] in
            var last = Date.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                if self.pollQuicklyUntil > .now || Date.now.timeIntervalSince(last) >= interval {
                    last = .now
                    self.pullCloudSoon()
                }
            }
        }
    }

    package func stopCloudPolling() {
        polling?.cancel(); polling = nil
    }

    private func pullCloudOnce() async -> Bool {
        guard let host, let cloud, host.replicaReadable, let me = host.replicaDeviceID else { return false }
        switch await cloud.availability() {
        case .available: break
        case .signedOut:
            moveSyncState(to: .signedOut)
            return false
        case let .unavailable(reason):
            moveSyncState(to: .failed(reason))
            return false
        }
        let fromStart = readAllNext
        readAllNext = false
        let failuresBefore = host.replicaSaveFailures
        do {
            let changes = try await cloud.fetchCloudChanges(since: fromStart ? nil : host.replica.cloudCheckpoint.changeToken)
            let pull = ReplicaPull(changes, after: host.replica.cloudCheckpoint)
            guard host.updateReplica({ $0.forgetLost(in: pull) }) else {
                moveSyncState(to: .failed("This device could not save what iCloud brought."))
                return false
            }
            let taken = try await takeWholePull(pull, me: me, from: cloud)
            // This device left the keyring while the pull was taken in: nothing more of it is kept.
            guard host.replicaDeviceID == me else { return true }
            guard taken, host.replicaSaveFailures == failuresBefore,
                  host.updateReplica({ $0.cloudCheckpoint = pull.nextCheckpoint(readAllAgain: self.readAllNext) }) else {
                moveSyncState(to: .failed("This device could not save what iCloud brought."))
                return false
            }
            let recovered = state != .syncing
            moveSyncState(to: .syncing)
            // Back from signed out or failing, or a push left something unwritten: push now.
            if recovered || host.replica.cloudPushPending(by: me) { pushCloudSoon() }
            host.cloudPullFinished(peerChanges: changes.records.filter { $0.writer != me }.count)
            return true
        } catch {
            host.replicaLog.noteDeviceEvent("cloud", "pull-failed", ["reason": "\(error)"])
            moveSyncState(to: .failed("\(error)"))
            return false
        }
    }

    /// Every record one pull brought, Members first. False when one could not be saved here.
    private func takeWholePull(_ pull: ReplicaPull, me: String, from cloud: any CloudPipe) async throws -> Bool {
        guard let host else { return false }
        // Records not taken in yet, fetched again by name: their record may not have changed since.
        for name in pull.namesToRetry { pull.takeRefetchedRecord(name, try await cloud.fetchCloudRecord(named: name)) }
        for record in pull.records where record.name == CloudRecordKind.members { await takeMembersRecord(record, me: me) }
        guard host.replicaDeviceID == me else { return true }
        // A push address or mailbox written before the Members that lists its writer was passed over then.
        if pull.changes.fullRescan || pull.records.contains(where: { $0.name == CloudRecordKind.members }) {
            let seen = Set(pull.records.map(\.name))
            for name in host.replica.missingPeerRecords(ownDeviceID: me, ownMachineID: host.replicaMachineID) where !seen.contains(name) {
                pull.takeRefetchedRecord(name, try await cloud.fetchCloudRecord(named: name))
            }
        }
        for record in pull.peerRecords("push-", notBy: me) { receivePushRegistration(record.payload) }
        let taken = await takeSealedRecords(pull, me: me)
        guard host.replicaDeviceID == me else { return true }
        await host.receiveCloudJoins(from: pull)
        for record in pull.peerRecords("mailbox-", notBy: me) where mailboxes.takeCloudMailboxRecord(record, pull: pull, me: me) { pushCloudSoon() }
        return taken
    }

    /// iCloud's Members record: another device's revisions taken, and whether iCloud holds this device's.
    private func takeMembersRecord(_ record: CloudRecord, me: String) async {
        guard record.kind == CloudRecordKind.members else {
            host?.updateReplica { $0.cloudAcceptedMembers = nil }
            return
        }
        if record.writer != me { return await receiveCloudMembers(record.payload) }
        host?.updateReplica { $0.noteCloudMembers(record.payload) }
    }

    /// Every revision in an iCloud Members payload newer than the one held, oldest first, each checked against
    /// the one before (`intake`: the host's, unless a caller already holds its lock on Members). With no list of
    /// its own yet, a device starts only from a revision it signed itself that names it: a list it never signed
    /// is another keyring's, or forged by whoever can write to iCloud, and is left alone.
    package func receiveCloudMembers(_ payload: Data, through intake: ((Data) async -> PeerIntakeOutcome)? = nil) async {
        guard let host, let me = host.replicaDeviceID else { return }
        var revisions = CloudMembers.revisions(payload)
        if host.replica.currentMembers == nil {
            guard let own = host.replicaSigningPublicKey, let first = revisions.firstIndex(where: { revision in
                revision.signerKeyID == me && (try? Members(serializedBytes: revision.payload))?.devices
                    .contains { $0.keyID == me && $0.signingPublicKey == own } == true
            }), (try? CredentialSealing.verifySignedMembers(revisions[first], current: nil)) != nil else {
                host.replicaLog.noteDeviceEvent("cloud", "members-not-ours", ["revisions": "\(revisions.count)"])
                return
            }
            revisions = Array(revisions[first...])
        }
        let receive = intake ?? { await host.receiveSignedMembers($0) }
        for revision in revisions where CloudMembers.revision(revision) > (host.replica.currentMembers?.revision ?? 0) {
            guard host.replicaDeviceID == me, let bytes = try? revision.serializedData() else { return }
            _ = await receive(bytes)
        }
        guard host.replicaDeviceID == me else { return }
        host.updateReplica { $0.noteCloudMembers(payload) }
    }

    /// A device's push address, signed by its reply key (an Apple Watch's by its iPhone's): the newest is kept,
    /// shared, and sent in mailboxes so a computer can wake that device.
    @discardableResult
    package func receivePushRegistration(_ signed: Data) -> PeerIntakeOutcome {
        guard let host, let members = host.replica.currentMembers else {
            return .refused("A push registration is signed by a device in the list of devices.")
        }
        var verified: VerifiedPushRegistration?
        var refusal: String?
        let saved = host.updateReplica { replica in
            do { verified = try replica.takePushRegistration(signed, members: members) } catch CloudPushRegistrationError.invalidFields {
                refusal = "A push registration needs a push address, a topic and a notice key."
            } catch CloudPushRegistrationError.unauthorizedSigner {
                refusal = "A device registers its own push address, or its iPhone registers its Apple Watch's."
            } catch {
                refusal = "A push registration is signed by a device in the list of devices."
            }
        }
        if let refusal { return .refused(refusal) }
        // A newer one is held: the newest wins.
        guard let verified else { return .taken }
        guard saved else { return .notSaved("The push registration was not saved.") }
        pushCloudSoon()
        mailboxes.writeMailboxSlotsSoon()
        host.replicaLog.noteDeviceEvent("push", "registered", ["device": verified.target.label,
                                                               "production": "\(verified.registration.apnsProduction)"])
        return .taken
    }

    /// The catalogues, vaults and copies one pull brought. False when one could not be saved.
    private func takeSealedRecords(_ pull: ReplicaPull, me: String) async -> Bool {
        takingSealedRecords = true
        defer { takingSealedRecords = false }
        let catalogues = pull.records.filter { $0.name == CloudRecordKind.catalogue } + pull.peerRecords("contested-", notBy: me)
        var taken = true
        for record in catalogues where !(await takeCatalogueRecord(record, pull: pull, me: me)) { taken = false }
        let vaults = pull.peerRecords("vault-", notBy: me)
        for record in vaults where !(await takeVaultRecord(record, pull: pull, me: me)) { taken = false }
        let copies = pull.peerRecords("copies-", notBy: me)
        for record in copies where !(await takeCopiesRecord(record, pull: pull)) { taken = false }
        takingSealedRecords = false
        if !catalogues.isEmpty || !vaults.isEmpty || !copies.isEmpty { await host?.cloudSealedRecordsTaken() }
        return taken
    }

    /// The shared catalogue record, or another device's `contested-` one: a later one taken, one signed apart
    /// merged in, and whether iCloud holds this device's. False when it could not be saved: the pull then leaves
    /// its checkpoint where it was, and the record is taken again.
    private func takeCatalogueRecord(_ record: CloudRecord, pull: ReplicaPull, me: String) async -> Bool {
        guard let host else { return false }
        let shared = record.name == CloudRecordKind.catalogue
        let notAccepted = { if shared { host.updateReplica { $0.cloudAcceptedCatalogue = nil } } }
        guard shared ? record.kind == CloudRecordKind.catalogue : record.kind == CloudRecordKind.contested(record.writer) else {
            notAccepted()
            pull.clearRecordRetry(record.name)
            return true
        }
        guard let opener = host.replicaKeyOpener,
              let opened = CloudEnvelope.openCloudEnvelope(record.payload, expectedKind: record.kind, deviceID: me, opener: opener) else {
            notAccepted()
            pull.markRecordForRetry(record.name)
            return true
        }
        let signer = (try? SignedDocument(serializedBytes: opened.plaintext))?.signerKeyID ?? ""
        guard let listed = host.replica.lists(device: signer) else {
            // Signed by a device the Members held here does not list yet: taken once the Members that lists it is.
            notAccepted()
            pull.markRecordForRetry(record.name)
            return true
        }
        if listed, record.writer != me, case .notSaved = await host.receiveSignedCatalogue(opened.plaintext) {
            notAccepted()
            pull.markRecordForRetry(record.name)
            return false
        }
        pull.clearRecordRetry(record.name)
        if shared { host.updateReplica { $0.noteCloudCatalogue(opened) } }
        return true
    }

    /// Another device's vault, to fold in. False when it could not be saved.
    private func takeVaultRecord(_ record: CloudRecord, pull: ReplicaPull, me: String) async -> Bool {
        guard let host else { return false }
        guard let members = host.replica.currentMembers, let opener = host.replicaKeyOpener,
              let opened = CloudEnvelope.openCloudEnvelope(record.payload, expectedKind: record.kind, deviceID: me, opener: opener) else {
            pull.markRecordForRetry(record.name)
            return true
        }
        guard let document = try? SignedDocument(serializedBytes: opened.plaintext),
              let vault = try? VaultDocument.opened(document, writer: record.writer, members: members) else {
            // A writer the Members held here does not list yet: folded in once the Members that lists it is.
            if host.replica.lists(device: record.writer) == nil { pull.markRecordForRetry(record.name) } else { pull.clearRecordRetry(record.name) }
            return true
        }
        guard await host.receivePeerVault(vault) else { return false }
        pull.clearRecordRetry(record.name)
        return true
    }

    /// Copies for a device or computer in the list that this device keeps copies for. Copies of a version the
    /// catalogue does not list yet are tried again after the next pull, which may bring the catalogue that lists
    /// them. False when they could not be saved.
    private func takeCopiesRecord(_ record: CloudRecord, pull: ReplicaPull) async -> Bool {
        guard let host else { return false }
        let recipient = String(record.kind.dropFirst("copies-".count))
        guard let members = host.replica.currentMembers,
              members.devices.contains(where: { $0.keyID == recipient }) || members.machines.contains(where: { $0.machineID == recipient }),
              host.takesCloudCopies(for: recipient) else {
            pull.clearRecordRetry(record.name)
            return true
        }
        guard let catalogue = host.replica.effectiveCatalogue else {
            pull.markRecordForRetry(record.name)
            return true
        }
        let good = CloudCopies.checked(record.payload, for: recipient, members: members, catalogue: catalogue)
        let all = (try? Agentkeyring_V2_SealedLogins(serializedBytes: record.payload))?.logins.count ?? 0
        if !good.isEmpty, await host.receiveCheckedCloudCopies(good, for: recipient) == .notSaved {
            pull.markRecordForRetry(record.name)
            return false
        }
        if good.count < all { pull.markRecordForRetry(record.name) } else { pull.clearRecordRetry(record.name) }
        return true
    }

    // MARK: Pushing

    /// Something this device keeps changed: written to iCloud a moment later, once.
    package func pushCloudSoon() {
        guard cloud != nil else { return }
        pushing?.cancel()
        pushing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.pushCloudNow()
        }
    }

    /// This device's own vault, signed: the document is signed again only when the vault changed.
    func signedVaultDocument(_ vault: CredentialVault, signer: PayloadReplySigner) throws -> Data {
        if let vaultDocument, vaultDocument.vault == vault { return vaultDocument.bytes }
        let signed = try VaultDocument.signedVaultDocument(vault, signer: signer).serializedData()
        vaultDocument = (vault, signed)
        return signed
    }
}
