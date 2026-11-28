// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt for the direct protocol, with no relay, on 2026.11.21;
// the doors cut on 2026.11.24; the lists as a KeyringReplica, split across files, on 2026.11.27 by model claude opus 5.5.
//
// The iPhone as an approving device. It joins a Mac or another iPhone through
// iCloud, keeps the signed Members and Catalogue and its own copy of every
// password from iCloud, learns of requests from their pushes, and answers in
// the request's answer box at the relay: Approve opens its own copy after
// Face ID and seals it again for the asking computer; Deny with words is
// signed with the reply key; plain Deny is unsigned and grants nothing.
// Nothing depends on reaching the iPhone: it learns only when it dials out,
// or from a push. iCloud is PhoneCloud.swift, requests PhoneRequests.swift,
// rules and devices PhoneDevices.swift, Apple Watch PhoneWatch.swift.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security
import UserNotifications

@MainActor
public final class PhoneKeyringEngine: PhoneBackend {
    let directory: URL
    let shared: PhoneSharedContext
    let keys: any PhoneDeviceKeys
    let identity: @MainActor () throws -> DeviceTLSIdentity
    var state = PhoneSavedState()
    var subscribers: [UUID: AsyncStream<PhoneSnapshot>.Continuation] = [:]
    let logger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Keyring")

    /// `cloud`: the user's iCloud private database by default; nil where the app names no container (tests).
    public init(directory: URL, shared: PhoneSharedContext, keys: any PhoneDeviceKeys,
                identity: @escaping @MainActor () throws -> DeviceTLSIdentity, cloud: (any CloudPipe)? = CloudVault()) {
        self.directory = directory
        self.shared = shared
        self.keys = keys
        self.identity = identity
        cloudSync = CloudReplicaSyncCoordinator(cloud: cloud)
        loadState()
        cloudSync.attachReplicaHost(self)
        // A new install: a Watch paired with the iPhone before still holds the old keyring.
        if !watchResetSaved { recordWatchReset() }
    }

    /// iOS keeps `phone-v2.pb` locked until the first unlock after a restart. While it is, nothing is written
    /// over it and nothing starts; `startBackgroundWork()` reads it again.
    var stateFileLocked = false

    private enum SavedStateRead { case missing, locked(any Error), undecodable(any Error), loaded(PhoneSavedState) }

    private func readSavedState() -> SavedStateRead {
        let data: Data
        do { data = try Data(contentsOf: stateURL) } catch CocoaError.fileReadNoSuchFile { return .missing } catch { return .locked(error) }
        do { return .loaded(try PhoneSavedState.decodeProtobuf(data)) } catch { return .undecodable(error) }
    }

    /// Reads the saved state. False while iOS keeps it locked. State this build cannot decode is replaced
    /// with a fresh one, saved, so first run starts again; the notification extension forgets the old lists and
    /// a paired Apple Watch is told to wipe the old keyring.
    @discardableResult
    func loadState() -> Bool {
        switch readSavedState() {
        case .missing:
            state = PhoneSavedState()
        case let .locked(error):
            stateFileLocked = true
            logger.error("The iPhone's state could not be read yet: \(String(describing: error), privacy: .public)")
            return false
        case let .undecodable(error):
            logger.error("The iPhone's state could not be decoded and starts again: \(String(describing: error), privacy: .public)")
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("state", "undecodable, starting again", ["error": "\(error)"])
            state = PhoneSavedState()
            stateFileLocked = false
            shared.deleteSharedContext()
            recordWatchReset()
            save(state)
        case let .loaded(saved):
            state = saved
        }
        stateFileLocked = false
        firstRun = (state.firstRun ?? (state.deviceKeyID == nil ? .start : .notifications)).restored
        if let pendingID = state.watchCopiesPending,
           members?.devices.contains(where: { $0.kind == .watch && $0.keyID == pendingID }) == true {
            watchEnrollment = .enrolledDeliveryPending(flow: nil, watchKeyID: pendingID, hold: nil)
        }
        return true
    }

    var snapshotRevision: UInt64 = 1
    /// iCloud and computers' mailboxes (PhoneCloud.swift).
    package let cloudSync: CloudReplicaSyncCoordinator<PhoneKeyringEngine>
    /// Import tokens already taken: Passwords can hand the same export over twice.
    var handledImportTokens: Set<UUID> = []
    var addComputerFlow: PhoneAddComputer? { didSet { if addComputerFlow != oldValue { publish() } } }
    var addingComputer: Task<Void, Never>?
    var computerJoin: (request: Agentkeyring_V2_JoinRequest, secret: Data, keys: ComputerJoinCodeKeys, relay: RelayBoxClient, until: Date)?
    var approvingComputer = false
    /// The Mac or iPhone being added through iCloud, by name, while its copies are encrypted.
    var addingDevice: String?
    var passwordsCopy = PhonePasswordsCopy() { didSet { if passwordsCopy != oldValue { publish() } } }
    /// Retry these envelopes once the iPhone has fetched newer Members.
    var unverifiedRequestEnvelopes: [String: Agentkeyring_V2_SignedRequestEnvelope] = [:]
    /// Request IDs answered on Apple Watch whose outcome push has not arrived yet.
    var watchDismissedIDs: Set<String> = []
    var requestExpiryTimer: Task<Void, Never>?
    /// Apple Watch's copies (PhoneWatchCopies.swift): the next generation's send, and how it is sent.
    var watchCopiesSyncing: Task<Void, Never>?
    /// The app sends Apple Watch a generation of its copies: the serialized WatchCopies and its generation.
    public var onWatchCopies: ((Data, UInt64) -> Void)?
    /// Fired when this iPhone answers or receives an outcome for a request so Apple Watch can clear its alert at once.
    public var onRequestDismissed: ((String) -> Void)?
    /// Practice requests this iPhone made and is waiting on (PhonePractice.swift), by id, and how the last
    /// one for each device ended.
    var practiceAsks: [String: Agentkeyring_V2_SignedRequestEnvelope] = [:]
    var practiceBoxTasks: [String: Task<Void, Never>] = [:]
    var practiceEnded: [String: Agentkeyring_V2_Lease] = [:]
    /// How this iPhone pushes its own practice requests: through push.opentrawl.sh (a test points it elsewhere).
    public var pusher = ApplePush()
    /// Background Apple Intelligence classification pass for unlisted phone logins.
    var categorySortingTask: Task<Void, Never>?

    // State the extensions in the other files keep.
    /// Called when this joined iPhone needs iOS to supply a push token.
    public var onNeedPushAddress: (() -> Void)?
    var pushRegistering: Task<Void, Never>?
    var pushState: PushRegistrationState = .none { didSet { if pushState != oldValue { publish() } } }
    var inFlightAnswers: [String: Bool] = [:]
    /// Answers that cannot reach the relay yet and are still being retried.
    var undelivered: Set<String> = []
    var looking: Task<Void, Never>?
    /// The join card the look last found.
    var foundMac: Agentkeyring_V2_JoinInvite? { didSet { if foundMac != oldValue { publish() } } }
    /// The invitation in iCloud Keychain every device of the user's shares: a test peer hands in its own.
    package var invitationStore = CloudKeychainInvitationStore.iCloudKeychain(
        accessGroup: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String ?? "")
    var joining: Task<Void, Never>?
    var joiningGeneration: UInt64 = 0
    var withdrawing: Task<Void, Never>?
    var receivingTask: Task<Void, Never>?
    /// What iOS allows, as the app last read it: for the checklist and whether a practice push will come.
    var facts = PhoneNotificationFacts() { didSet { publish() } }
    /// The app hands the lists and settings to Apple Watch whenever they change.
    public var onListsChanged: (() -> Void)?
    var practiceTimer: Task<Void, Never>?
    var practiceTask: Task<Void, Never>?
    var watchPaired = false
    var watchInstalled = false
    var watchEnrollment: WatchEnrollment = .none
    var addingWatchGeneration: UInt64 = 0
    /// Fired when the iPhone's Face ID offer for Apple Watch starts, updates, or ends.
    public var onWatchMayAsk: (() -> Void)?

    // MARK: First run

    /// Where first run stands: the one state every first-run screen and step follows.
    private(set) var firstRun = PhoneFirstRun.start

    /// Moves first run on by its table, saves it, and starts what the new state asks for.
    func apply(_ event: PhoneFirstRunEvent) {
        let next = firstRun.on(event)
        guard next != firstRun else { return }
        let previous = firstRun
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("firstrun", "moved", ["from": "\(firstRun)", "to": "\(next)", "by": "\(event)"])
        firstRun = next
        var saved = state
        saved.firstRun = next
        if case .addComputer = previous, event == .done {
            saved.pendingComputerDelivery = nil
        }
        save(saved)
        if next.looksForMac { lookForMac() }
        if next.mayJoin, !previous.mayJoin { joinMac() }
        if case .waitingForMac = previous, event == .cancel {
            joiningGeneration &+= 1
            joining?.cancel(); joining = nil
            withdrawing?.cancel()
            withdrawing = Task { await withdrawJoin() }
        }
        if next == .receivingPasswords {
            ensurePushRegistration()
            startReceivingPasswords()
        }
        if next == .importPasswords { ensurePushRegistration() }
        // A new practice request: clear any previous denial reply, start the 30-second timer, and drive practice via syncPractice().
        if case let .practiceWaiting(id, false) = next, previous.practiceID != id {
            if state.lastPracticeReply != nil {
                var updated = state
                updated.lastPracticeReply = nil
                save(updated)
            }
            syncPractice(resetTimer: true)
        }
        if event == .practiceDismissed { practiceTimer?.cancel(); practiceTimer = nil }
        if next == .addWatch, addWatchFlow == nil { openAddWatch() }
    }

    /// A tap on a first-run screen, or what iOS answered about notifications.
    public func sendFirstRunEvent(_ event: PhoneFirstRunEvent) async { apply(event) }

    // MARK: Keeping up with the other devices

    /// In front: until joined, look for a join card; once joined, fetch what changed, pick up requests whose
    /// notifications are on the Lock Screen, and rejoin first run's practice request by its id.
    public func startBackgroundWork() {
        guard !stateFileLocked || loadState() else { return }
        guard state.deviceKeyID != nil else {
            if firstRun.looksForMac { lookForMac() }
            if firstRun.mayJoin { joinMac() }
            return
        }
        leaveInvitation()
        ensurePushRegistration()
        catchUpWatchCopies()
        pruneExpiredEnvelopes()
        scheduleRequestExpiryTimer()
        if let rawPush = state.watchPush,
           let push = try? Agentkeyring_V2_PushRegistration(serializedBytes: rawPush),
           listedWatch?.keyID == push.deviceKeyID {
            Task { [weak self] in await self?.registerWatchPush(push, raw: rawPush) }
        }
        Task { await refresh() }
        Task { await recheckDeviceJoin() }
        Task { await readDeliveredNotifications() }
        syncPractice()
        if firstRun == .receivingPasswords { startReceivingPasswords() }
        if firstRun == .addWatch, addWatchFlow == nil { openAddWatch() }
        refreshPasswordsCopy()
        cloudSync.mailboxes.keepMailboxSlotsFresh()
        // While in front: iCloud is read every 15 seconds, as CloudKit's pushes are a nudge Apple may hold back,
        // so a Mac asking to join shows here without waiting for one.
        cloudSync.startCloudPolling(every: 15)
        sortUnlistedPhoneLoginsIfNeeded()
    }

    /// Leaving the screen. A held Face ID confirmation stays until its deadline: iOS may keep the app.
    public func stopBackgroundWork() {
        cloudSync.stopCloudPolling()
        looking?.cancel(); looking = nil
        categorySortingTask?.cancel(); categorySortingTask = nil
        requestExpiryTimer?.cancel(); requestExpiryTimer = nil
    }

    /// Classifies and caches any unlisted phone logins once on device using Apple Intelligence.
    func sortUnlistedPhoneLoginsIfNeeded() {
        guard categorySortingTask == nil,
              OnDeviceCategoryClassifier.shared.isAvailable,
              let logins = catalogue?.logins,
              !logins.isEmpty
        else { return }
        let unlisted: [OnDeviceClassificationItem] = logins.compactMap { login in
            let site = Self.site(login)
            if DomainClassifier.classify(site: site) != nil { return nil }
            if OnDeviceCategoryClassifier.shared.cachedCategory(forSite: site) != nil { return nil }
            return OnDeviceClassificationItem(id: UUID(), host: site, title: login.title)
        }
        guard !unlisted.isEmpty else { return }
        categorySortingTask = Task { @MainActor [weak self] in
            defer { self?.categorySortingTask = nil }
            let stream = OnDeviceCategoryClassifier.shared.classifyStreaming(unlisted)
            var updated = false
            for await _ in stream {
                guard !Task.isCancelled, self != nil else { return }
                updated = true
            }
            if updated, let self, !Task.isCancelled {
                self.publish()
            }
        }
    }

    var copiesHeld = 0
    var copiesExpected: Int?

    // MARK: Saving

    var stateURL: URL { directory.appending(path: "phone-v2.pb") }

    // An iCloud pull can span several saves, including saves in its join and Watch handlers.
    package private(set) var replicaSaveFailures: UInt64 = 0

    @discardableResult
    func save(_ next: PhoneSavedState) -> Bool {
        guard !stateFileLocked else {
            replicaSaveFailures &+= 1
            logger.error("The iPhone's state was not saved: iOS keeps the saved one locked.")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try next.encodeProtobuf()
            #if os(iOS)
            try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: stateURL, options: .atomic)
            #endif
        } catch {
            replicaSaveFailures &+= 1
            logger.error("Could not save the iPhone's state: \(String(describing: error), privacy: .public)")
            return false
        }
        let sharedChanged = next.members != state.members || next.catalogue != state.catalogue || next.deviceKeyID != state.deviceKeyID
            || next.settings != state.settings
        let envelopesChanged = next.requestEnvelopes != state.requestEnvelopes
        state = next
        if sharedChanged {
            shared.writeSnapshot(PhoneSharedSnapshot(
                deviceKeyID: next.deviceKeyID,
                members: next.members,
                catalogue: next.catalogue,
                settings: next.settings
            ))
        }
        if envelopesChanged { scheduleRequestExpiryTimer() }
        publish()
        return true
    }
}
