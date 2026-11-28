// Written by AI on 2026.11.18 by model claude opus 5.5; rebuilt on 2026.11.21
// by the same model for the direct design, with no relay; the doors cut on 2026.11.24;
// lists kept as a KeyringReplica, split into MacMembers.swift and MacKeychainStateStore.swift, on 2026.11.27.
//
// The Mac as an approving device that keeps Josh's lists: the signed members
// list and catalogue, every sealed copy (MacVaultFileStore) and each device's push
// address. They pass to his other Apple devices through his iCloud private
// database (MacCloud.swift), and to computers through their update mailboxes
// at the box relay (AgentKeyringEngine/Cloud/ComputerMailboxPublisher.swift); computers join with a code
// (MacJoins.swift). Its own agents' requests go to the iPhone and Apple Watch
// as pushes this Mac sends to Apple, and come back in their answer boxes
// (MacOutgoingApprovalRequests.swift). Agents' requests on other computers reach it as pushes, are
// shown here too, and are answered in their own answer boxes (MacRemoteAsks.swift).
// What it signs with Touch ID is in MacMembers.swift.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Observation
import Security
import SwiftProtobuf

let deviceLogger = Logger(subsystem: "com.agentkeyring.app", category: "Device")

/// What differs between the app and a test: where pushes go, where things are kept.
public struct MacSyncEnvironment {
    public var gateway = ApplePushGateway.apple
    /// Stateless blind push relay used when no local .p8 key is installed. Nil disables relay fallback.
    public var pushRelayURL: URL? = Self.defaultPushRelayURL()
    public var storage: MacKeychainStateStore

    private static func defaultPushRelayURL() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["AGENT_KEYRING_PUSH_RELAY_URL"] {
            if raw.isEmpty || raw == "none" || raw == "off" { return nil }
            return URL(string: raw)
        }
        return ApplePush.defaultRelayURL
    }
    /// The relay this Mac's own requests are answered at, and its mailbox writes go to.
    public var relay = RelayBoxClient.configured
    /// The invitation left in iCloud Keychain for a new iPhone or Mac.
    public var invitationStore = Self.iCloudInvitationStore
    /// The invitation in iCloud Keychain, in the group this Mac shares with the user's iPhone.
    public static var iCloudInvitationStore: CloudKeychainInvitationStore {
        .iCloudKeychain(accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringSharedKeychainGroup") as? String ?? "")
    }
    public var complaints: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/complaints.pb")
    /// The user's iCloud private database; nil in tests and when the app names no container.
    public var cloud: (any CloudPipe)?
    public init(storage: MacKeychainStateStore) { self.storage = storage }
}

@MainActor @Observable
public final class MacSyncCoordinator {
    nonisolated static let savedProtobufMagic = Data("AKRDEV02".utf8)

    /// What the Mac keeps between launches, beside the sealed copies in MacVaultFileStore: small enough for one
    /// keychain item, and written whole, so the iCloud checkpoint never moves without what it brought.
    package struct MacSavedLists: KeyringReplica, Equatable {
        enum SavedListsDecodeFailure: Error { case invalidMagic }

        package var members: Data?
        package var membersHistory: [Data] = []
        package var catalogue: Data?
        package var contestedCatalogues: [Data] = []
        var catalogueRevision: UInt64 = 0
        var copiesRevision: UInt64 = 0
        package var pushRegistrations: [String: Data] = [:]
        package var mailboxes: [String: Data] = [:]
        package var cloudAcceptedMembers: Data?
        package var cloudAcceptedCatalogue: Data?
        package var cloudCheckpoint = CloudCheckpoint()

        init() {}

        init(storedProto proto: Agentkeyring_V2_StoredMacDevice) {
            members = proto.hasMembers ? proto.members : nil
            membersHistory = proto.membersHistory
            catalogue = proto.hasCatalogue ? proto.catalogue : nil
            contestedCatalogues = proto.contestedCatalogues
            catalogueRevision = proto.catalogueRevision
            copiesRevision = proto.copiesRevision
            pushRegistrations = proto.registrations
            mailboxes = proto.mailboxes
            cloudAcceptedMembers = proto.hasCloudAcceptedMembers ? proto.cloudAcceptedMembers : nil
            cloudAcceptedCatalogue = proto.hasCloudAcceptedCatalogue ? proto.cloudAcceptedCatalogue : nil
            cloudCheckpoint = CloudCheckpoint(stored: proto.cloudCheckpoint)
        }

        func storedProto() -> Agentkeyring_V2_StoredMacDevice {
            var proto = Agentkeyring_V2_StoredMacDevice()
            if let members { proto.members = members }
            proto.membersHistory = membersHistory
            if let catalogue { proto.catalogue = catalogue }
            proto.contestedCatalogues = contestedCatalogues
            proto.catalogueRevision = catalogueRevision
            proto.copiesRevision = copiesRevision
            proto.registrations = pushRegistrations
            proto.mailboxes = mailboxes
            if let cloudAcceptedMembers { proto.cloudAcceptedMembers = cloudAcceptedMembers }
            if let cloudAcceptedCatalogue { proto.cloudAcceptedCatalogue = cloudAcceptedCatalogue }
            proto.cloudCheckpoint = cloudCheckpoint.stored
            return proto
        }

        static func decodeProtobuf(_ bytes: Data) throws -> MacSavedLists {
            guard bytes.starts(with: MacSyncCoordinator.savedProtobufMagic) else { throw SavedListsDecodeFailure.invalidMagic }
            let proto = try Agentkeyring_V2_StoredMacDevice(
                serializedBytes: Data(bytes.dropFirst(MacSyncCoordinator.savedProtobufMagic.count))
            )
            return MacSavedLists(storedProto: proto)
        }
    }

    public internal(set) var members: Agentkeyring_V2_Members?
    /// The catalogue as last signed: what devices and computers are given.
    /// Merged with any catalogue kept beside it while contested.
    public internal(set) var catalogue: Agentkeyring_V2_Catalogue?
    var saved = MacSavedLists()
    /// The keychain could not be read at launch (it is locked, or it failed). While it cannot, nothing is
    /// written over the lists and nothing syncs: they are read again every half minute (`retryLoadSavedLists`).
    public private(set) var savedListsLocked = false
    @ObservationIgnored private var savedListsRetry: Task<Void, Never>?
    /// Observed: the Devices tab drops its "no push key" notice when the key arrives.
    var push: ApplePush?
    @ObservationIgnored private(set) var started = false
    @ObservationIgnored var revPush: Task<Void, Never>?

    let keys: MacKeys
    let store: MacVaultFileStore
    let leaseStore: CredentialLeaseStore
    let environment: MacSyncEnvironment
    /// The logins and their rules as the catalogue, from the app's import and rules.
    let catalogueLogins: @MainActor () async throws -> [Agentkeyring_V2_Login]
    /// A newer catalogue the iPhone signed (a rule changed there), with this Mac's own Automatic copies as it now holds them.
    /// This Mac's list says no device holds the password (deleted when it was Blocked), whatever the signed catalogue says yet.
    @ObservationIgnored var secretDeletedHere: (@MainActor (String) -> Bool)?
    /// The new catalogue, and the one it replaced: what its signer started from. Throws when its rules and
    /// copies could not be saved here, and the catalogue is then not taken.
    @ObservationIgnored var onCatalogue: (@MainActor (Agentkeyring_V2_Catalogue, Agentkeyring_V2_Catalogue?) async throws -> Void)?
    /// The catalogue was signed and sent: the other devices now hold this Mac's list as it is.
    @ObservationIgnored var onPublished: (@MainActor () async -> Void)?
    /// A device asked for a practice request on this Mac itself.
    @ObservationIgnored var onPracticeHere: (@MainActor () -> Void)?
    /// Membership or computer Automatic-copy state changed, so the app should refresh local Automatic status.
    @ObservationIgnored var onAutomaticCopiesChanged: (@MainActor () async -> Void)?

    // Joining (MacJoins.swift).
    var joinRecords: [String: HeardJoinRequest] = [:]
    @ObservationIgnored var invitations: [Data: Date] = [:]
    @ObservationIgnored var mayLeaveInvitation = true
    let joinSignal = MacWakeSignal()
    public internal(set) var filling: EnrollingDeviceCopyProgress?

    // Asking (MacOutgoingApprovalRequests.swift).
    struct AskTasks {
        var push: Task<Void, Never>?
        var answer: Task<Void, Never>?
        var grant: Task<Void, Never>?

        var isEmpty: Bool { push == nil && answer == nil && grant == nil }

        func cancelAll() {
            push?.cancel()
            answer?.cancel()
            grant?.cancel()
        }
    }
    var asks: [String: OutgoingApprovalRequest] = [:]
    let askSignal = MacWakeSignal()
    @ObservationIgnored var askTasks: [String: AskTasks] = [:]
    @ObservationIgnored var fillTask: Task<Void, Never>?
    @ObservationIgnored var joinBoxTasks: [Data: Task<Void, Never>] = [:]
    @ObservationIgnored private var countingOwnCopies: Task<Void, Never>?

    /// A new Mac's request, through iCloud, as the computer its agents run on, by its device key: added with its device.
    var cloudMachineJoins: [String: Agentkeyring_V2_Machine] = [:]
    /// A practice request another device made for this Mac, until it is answered here.
    @ObservationIgnored var devicePractice: Agentkeyring_V2_SignedRequestEnvelope?
    @ObservationIgnored var leaseFollowing: Task<Void, Never>?

    // Other computers' requests (MacRemoteAsks.swift).
    public internal(set) var remoteAsks: [String: RemoteComputerRequest] = [:]

    // iCloud and computers' mailboxes (MacCloud.swift).
    @ObservationIgnored package let cloudSync: CloudReplicaSyncCoordinator<MacSyncCoordinator>
    @ObservationIgnored package private(set) var replicaSaveFailures: UInt64 = 0
    /// Another device's vault from iCloud, for the app to fold into its own list. False when it could not be saved.
    @ObservationIgnored var onPeerVault: (@MainActor (CredentialVault) async -> Bool)?
    /// Another device signed a catalogue this Mac had not seen all of: its rules are merged in, and the
    /// merged list waits to be sent.
    @ObservationIgnored var onCatalogueConflict: (@MainActor () -> Void)?
    /// This Mac's vault as it is now, for iCloud.
    @ObservationIgnored var ownVault: (@MainActor () async -> CredentialVault?)?
    // Changes signed here run one at a time (MacMembers.swift).
    @ObservationIgnored var membersOperation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored var catalogueOperation: (id: UUID, task: Task<Void, Never>)?

    // Joining an iPhone's list through iCloud (MacJoinsIPhone.swift).
    public internal(set) var joiningIPhone: JoiningIPhone?
    @ObservationIgnored var iPhoneInvite: Agentkeyring_V2_JoinInvite?
    @ObservationIgnored var askingIPhone: Task<Void, Never>?
    @ObservationIgnored var iphoneJoinGeneration: UInt64 = 0
    @ObservationIgnored var iphoneJoinCleanup: Task<Void, Never>?

    init(keys: MacKeys, store: MacVaultFileStore, leaseStore: CredentialLeaseStore, environment: MacSyncEnvironment,
        catalogueLogins: @escaping @MainActor () async throws -> [Agentkeyring_V2_Login]) {
        self.keys = keys
        self.store = store
        self.leaseStore = leaseStore
        self.environment = environment
        self.catalogueLogins = catalogueLogins
        cloudSync = CloudReplicaSyncCoordinator(cloud: environment.cloud)
        loadSavedLists()
        cloudSync.attachReplicaHost(self)
        if let bytes = try? environment.storage.load("push"), let credential = try? Agentkeyring_V2_PushCredential(serializedBytes: bytes) {
            push = try? ApplePush(credential: credential, gateway: environment.gateway)
        } else if environment.gateway.pin == nil, let relayURL = environment.pushRelayURL {
            push = ApplePush(relayURL: relayURL, gateway: environment.gateway)
        }
    }

    /// Reads the saved lists. False while the keychain cannot be read: they are kept as they are, never written
    /// over with empty ones. Lists this build cannot decode are replaced with empty ones.
    @discardableResult
    private func loadSavedLists() -> Bool {
        let bytes: Data?
        do { bytes = try environment.storage.load("saved") } catch {
            deviceLogger.error("Saved device lists could not be read: \(String(describing: error), privacy: .public)")
            saved = MacSavedLists()
            savedListsLocked = true
            return false
        }
        savedListsLocked = false
        do { saved = try bytes.map(MacSavedLists.decodeProtobuf) ?? MacSavedLists() } catch {
            deviceLogger.error("Saved device lists could not be decoded and start again: \(String(describing: error), privacy: .public)")
            KeyringDiagnosticLog.mac.noteDeviceEvent("lists", "undecodable, starting again", ["error": "\(error)"])
            saved = MacSavedLists()
        }
        members = saved.currentMembers
        catalogue = nil
        if let members, let bytes = saved.catalogue, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes),
           (try? CredentialSealing.verifySignedCatalogue(signed, members: members, current: nil)) != nil {
            catalogue = saved.effectiveCatalogue
        }
        return true
    }

    /// The saved lists read again, after a launch that could not read them: true once they are, and the
    /// syncing `start()` held back then starts.
    @discardableResult
    public func retryLoadSavedLists() -> Bool {
        guard savedListsLocked else { return true }
        guard loadSavedLists() else { return false }
        savedListsRetry?.cancel(); savedListsRetry = nil
        if started { startSyncing() }
        return true
    }

    /// The relay set on this Mac (the `AgentKeyringRelayURL` setting), taken at launch before any device or
    /// environment reads `RelayBoxClient.configured`. Nil: the environment's, else the default.
    public static func useRelay(_ url: String?) { RelayBoxClient.overrideURL = url }

    /// The Mac has members: at least one device or computer has joined it.
    public var hasMembers: Bool { members != nil }
    /// How many passwords the signed catalogue lists that this Mac holds its own current copy of.
    public private(set) var ownCopiesHeld = 0
    public var ownMachineID: String { keys.machineID }
    public var ownDeviceID: String { keys.deviceKeyID }
    public var hasPushKey: Bool { push != nil }

    /// Writes the lists and the iCloud checkpoint in one item. False when they are not saved: the write failed,
    /// or what is saved could not be read at launch and must not be written over.
    @discardableResult
    func persist() -> Bool { persist(saved) }

    private func persist(_ lists: MacSavedLists) -> Bool {
        guard !savedListsLocked else {
            replicaSaveFailures &+= 1
            deviceLogger.error("The lists were not saved: the keychain could not be read at launch.")
            return false
        }
        do {
            let bytes = Self.savedProtobufMagic + (try lists.storedProto().serializedData())
            try environment.storage.write(bytes, "saved")
            return true
        } catch {
            replicaSaveFailures &+= 1
            deviceLogger.error("Could not save the lists: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Saves `change` made to the lists as they are now, and holds the result only once it is saved.
    @discardableResult
    package func updateReplica(_ change: (inout MacSavedLists) -> Void) -> Bool {
        var next = saved
        change(&next)
        guard next != saved else { return true }
        guard persist(next) else { return false }
        saved = next
        return true
    }

    /// Starts keeping up with the devices and computers, once: their answers, iCloud, the mailboxes, and
    /// the invitation in iCloud Keychain for a new iPhone or Mac.
    public func startBackgroundWork(leavingInvitation: Bool = true) {
        guard !started else { return }
        started = true
        mayLeaveInvitation = leavingInvitation
        followLeases()
        resumeAsks()
        if !savedListsLocked {
            startSyncing()
        } else {
            savedListsRetry = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, !Task.isCancelled, !self.retryLoadSavedLists() else { return }
                }
            }
        }
        scheduleCountOwnCopies()
    }

    /// iCloud, the mailboxes and the invitation: only from lists this Mac has read.
    private func startSyncing() {
        cloudSync.pullCloudSoon()
        cloudSync.startCloudPolling(every: 300)
        cloudSync.mailboxes.keepMailboxSlotsFresh()
        if mayLeaveInvitation { leaveInvitation() }
    }

    /// Cancels all background tasks and listeners on this device before tearing it down.
    public func stopBackgroundWork() {
        started = false
        cloudSync.stopCloudSync()
        revPush?.cancel(); revPush = nil
        leaseFollowing?.cancel(); leaseFollowing = nil
        askingIPhone?.cancel(); askingIPhone = nil
        fillTask?.cancel(); fillTask = nil
        countingOwnCopies?.cancel(); countingOwnCopies = nil
        savedListsRetry?.cancel(); savedListsRetry = nil
        for task in joinBoxTasks.values { task.cancel() }
        joinBoxTasks.removeAll()
        for tasks in askTasks.values { tasks.cancelAll() }
        askTasks.removeAll()
    }

    /// Drops the cached iCloud change token and re-pulls everything fresh.
    public func syncWithICloudNow() {
        cloudSync.readWholeCloudNext()
        cloudSync.pullCloudSoon()
    }

    func scheduleCountOwnCopies() {
        countingOwnCopies?.cancel()
        countingOwnCopies = Task { [weak self] in
            await self?.countOwnCopies()
        }
    }

    private func countOwnCopies() async {
        let listed = Dictionary((catalogue?.logins ?? []).filter(\.holdsSecret).map { ($0.loginID, $0.version) },
                                uniquingKeysWith: { first, _ in first })
        let sealed = (try? await store.sealed()) ?? []
        guard !Task.isCancelled else { return }
        ownCopiesHeld = Set(sealed.filter { $0.openerID == keys.deviceKeyID && listed[$0.loginID] == $0.version }.map(\.loginID)).count
    }

    /// This Mac's lines, in time order, for `agent-keyring logs`.
    public func logLines(since: Int64, request: String = "") -> [String] {
        KeyringDiagnosticLog.mac.lines(since: since, request: request).sorted()
    }

    // MARK: Complaints

    /// An agent's complaint on this Mac, kept in one owner-only file, oldest first; shown on no screen.
    public func keep(_ complaint: Agentkeyring_V2_Complaint) throws {
        var complaint = complaint
        guard complaint.summary.utf8.count <= 1000, complaint.detail.utf8.count <= 65_536 else {
            throw AgentRPCError(.invalidArgument, "Keep a complaint's summary to one line and its detail under 64 KB.")
        }
        if complaint.atUnixSeconds == 0 { complaint.atUnixSeconds = Int64(Date.now.timeIntervalSince1970) }
        var all = complaints(since: 0)
        all.complaints.append(complaint)
        all.complaints = Self.newest(all.complaints, within: Self.complaintsBytes)
        let file = environment.complaints
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try all.serializedData().write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        KeyringDiagnosticLog.mac.noteDeviceEvent("complaint", "kept", ["computer": complaint.computer])
    }

    /// All complaints go back to an agent in one socket frame (1 MiB), so the file is kept well under it.
    nonisolated static let complaintsBytes = 512 * 1024

    /// The newest complaints whose serialized list fits in `limit` bytes, oldest first.
    nonisolated static func newest(_ complaints: [Agentkeyring_V2_Complaint], within limit: Int) -> [Agentkeyring_V2_Complaint] {
        var total = 0
        var kept = 0
        for complaint in complaints.reversed() {
            let size = (try? complaint.serializedData().count) ?? limit
            // Each entry also takes a tag byte and a length of up to three bytes.
            total += size + 4
            guard total <= limit else { break }
            kept += 1
        }
        return Array(complaints.suffix(kept))
    }

    public func complaints(since: Int64) -> Agentkeyring_V2_Complaints {
        var all = (try? Data(contentsOf: environment.complaints)).flatMap { try? Agentkeyring_V2_Complaints(serializedBytes: $0) }
            ?? Agentkeyring_V2_Complaints()
        all.complaints = all.complaints.filter { $0.atUnixSeconds >= since }
        return all
    }

    // MARK: The push key

    /// The Apple developer team's push key, from `agent-keyring push-key`: kept
    /// in this app's keychain, used for this Mac's pushes and sealed to each
    /// computer that joins.
    public func setPushCredential(keyID: String, teamID: String, privateKey: Data) throws {
        guard !keyID.isEmpty, !teamID.isEmpty, (try? P256.Signing.PrivateKey(derRepresentation: privateKey)) != nil else {
            throw AgentRPCError(.invalidArgument, MessageCopy.invalidPushKey)
        }
        var credential = Agentkeyring_V2_PushCredential()
        credential.keyID = keyID
        credential.teamID = teamID
        credential.privateKey = privateKey
        let made = try ApplePush(credential: credential, gateway: environment.gateway)
        try environment.storage.write(credential.serializedData(), "push")
        push = made
        KeyringDiagnosticLog.mac.noteDeviceEvent("push", "key-saved", ["key_id": keyID])
    }
}
#endif
