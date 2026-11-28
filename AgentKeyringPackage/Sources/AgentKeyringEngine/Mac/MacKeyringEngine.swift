#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import AuthenticationServices
import Foundation
import LocalAuthentication
import OSLog
import Observation
import Security

@available(macOS 26.0, *)
@MainActor
@Observable
public final class MacKeyringEngine {
    public internal(set) var status: ImportedVaultStatus?
    public private(set) var isLoading = true
    /// What went wrong, for the window to show; nil once it is put right.
    public internal(set) var problem: String?
    public let accessControl: CredentialAccessController
    public var syncReminders: StalePasswordsReminders?

    let store: MacVaultFileStore
    let mapper: CredentialExchangeMapper
    let credentialImporter: any CredentialImporting
    let merger: VaultSnapshotMerger
    public let leaseStore: CredentialLeaseStore
    /// How often each password was asked for, approved and denied.
    public let usage: PasswordUsageLog
    /// This Mac as a place the lists live, once its keys exist.
    public private(set) var device: MacSyncCoordinator?
    @ObservationIgnored private var keys: MacKeys?
    /// This Mac's keys before first run (MacHardwareSetupFlow.swift): made, or waiting for him to choose how he uses this Mac.
    public private(set) var setup = MacHardwareSetupFlow.loading
    /// The list is being signed and sent to the other devices, after one Touch ID (MacUnsentChangesPublisher.swift).
    public internal(set) var sendingChanges = false
    /// The last copy from Passwords brought nothing the other devices lack.
    public internal(set) var lastCopyChangedNothing = false
    /// The list the other devices last received (MacUnsentChangesPublisher.swift); saved on every change.
    public internal(set) var sentList: [String: Date?]? {
        didSet { Self.saveSentList(sentList, in: settings) }
    }
    /// A password became Automatic (or a computer was upgraded/added), and an enrolled computer lacks a current copy.
    public internal(set) var automaticCopiesMissing = false
    /// Login IDs that currently have a valid, current-version local Automatic copy on this Mac.
    var localAutomaticCopyIDs: Set<String> = []
    /// Snapshot of `currentList` captured synchronously when `catalogueLogins()` builds a catalogue to publish.
    @ObservationIgnored var publishingListSnapshot: [String: Date?]?
    @ObservationIgnored var automaticCopiesChecked = false
    @ObservationIgnored var startupTask: Task<Void, Never>?
    @ObservationIgnored private var statusLoaded = false
    var isApprovingLease = false
    public internal(set) var leaseLogins: [CredentialCandidate] = []
    let bridge: AgentBridgeDirectory
    /// When this Mac last passed its practice request: Touch ID, its Secure Enclave keys and sealing work.
    public internal(set) var testedAt: Date?
    /// Rises when "Open at login" changes, so the screens read it again.
    var loginItemRevision = 0
    var telemetryRevision = 0
    /// Apple's push address for this Mac, kept until its keys exist.
    @ObservationIgnored var pushAddress: (token: Data, topic: String, production: Bool)?
    /// Where first run is (MacFirstRunFlow.swift); saved, so a restart resumes it.
    public private(set) var firstRun: MacFirstRunFlow
    @ObservationIgnored var exportTimeout: Task<Void, Never>?
    @ObservationIgnored var categorySortingTask: Task<Void, Never>?
    @ObservationIgnored var vaultCategorySortingTask: Task<Void, Never>?
    /// Bumped when background Apple Intelligence finishes sorting unlisted vault logins.
    public internal(set) var vaultCategoriesRevision = 0
    /// Enables background Apple Intelligence sorting for unlisted domains.
    public var enableBackgroundOnDeviceSorting = true
    /// Opens Apple Passwords for an export, calling `failed` if it cannot. A test puts in one that opens nothing.
    var openApplePasswords: @MainActor (_ failed: @escaping @MainActor @Sendable () -> Void) -> Void = MacKeyringEngine.launchApplePasswords
    /// Explicit selective-import state machine: owns flow visibility, navigation,
    /// export progress/timeout token, problem banner, and in-memory staged batch.
    public var importSession = SelectiveImportSession(path: .pickFew) {
        didSet {
            if importSession.exportState != .waiting || importSession.exportAttemptID != oldValue.exportAttemptID {
                exportTimeout?.cancel()
                exportTimeout = nil
            }
            if case .review = oldValue.phase {
                if case .review = importSession.phase {
                    // Staying in .review keeps background classification running.
                } else {
                    categorySortingTask?.cancel()
                    categorySortingTask = nil
                }
            }
            if importSession.exportState != oldValue.exportState {
                KeyringDiagnosticLog.mac.noteDeviceEvent("copy", "moved", ["to": "\(importSession.exportState)"])
            }
        }
    }
    /// He clicked Show Passwords at the end of first run. Until then the window opens at launch.
    public var firstRunFinished: Bool { firstRun.step == .finished }
    let settings: UserDefaults
    var handledTokens = Set<UUID>()
    var agentListener: AgentBridgeServer?

    public init(
        store: MacVaultFileStore = MacVaultFileStore(),
        credentialImporter: any CredentialImporting = SystemCredentialImporter(),
        mapper: CredentialExchangeMapper = CredentialExchangeMapper(),
        merger: VaultSnapshotMerger = VaultSnapshotMerger(),
        bridge: AgentBridgeDirectory = AgentBridgeDirectory(),
        accessControl: CredentialAccessController = CredentialAccessController(),
        leaseStore: CredentialLeaseStore = CredentialLeaseStore(),
        usage: PasswordUsageLog = PasswordUsageLog(),
        settings: UserDefaults = .standard
    ) {
        self.store = store
        self.credentialImporter = credentialImporter
        self.mapper = mapper
        self.merger = merger
        self.bridge = bridge
        self.accessControl = accessControl
        self.settings = settings
        self.leaseStore = leaseStore
        self.usage = usage
        testedAt = settings.object(forKey: Self.testedAtKey) as? Date
        firstRun = Self.savedFirstRun(settings)
        sentList = Self.savedSentList(settings)
        leaseStore.onDecision = { [usage, weak self] id, login, event in
            usage.noteUsage(event, request: id, login: login)
            guard event != .asked else { return }
            // After the store has saved the lease, so its requester is there to name.
            Task { @MainActor in self?.noteAgentAnswered(lease: id, approved: event == .approved) }
        }
        accessControl.beforeSave = { [weak self] old, new, context in
            try await self?.applyRuleChange(from: old, to: new, context: context)
        }
        // Only once the new rules are published and saved: a change that fails deletes nothing.
        accessControl.afterSave = { [weak self] old, new in
            await self?.deleteSecretsOrReport(of: Set(new.filter { $0.value == .blocked && old[$0.key] != .blocked }.keys))
        }
        accessControl.onRulesChanged = { [weak self] in
            guard let self else { return }
            try? self.leaseStore.reconcile(logins: self.leaseLogins, rules: self.currentRules)
        }
        accessControl.onRollback = { [weak self] in
            await self?.noteMissingAutomaticCopies()
        }
    }

    static let installedKey = "installed"

    /// A fresh container is a new install: what a previous one left in the
    /// keychain (its relay and members, its rules) goes, so first run starts
    /// from Welcome with nothing behind it. This Mac's own keys stay. The
    /// invitation in iCloud Keychain goes only if this Mac left it: it is
    /// shared by all his devices, and on a Mac being set up for agents it
    /// belongs to his other Mac. Call before the model is made.
    public static func forgetPreviousInstall(settings: UserDefaults = .standard, invitation: CloudKeychainInvitationStore = MacSyncEnvironment.iCloudInvitationStore,
                                             ownKeyID: @MainActor () -> String? = { (try? MacKeys.loadMacKeys())?.deviceKeyID },
                                             forgetLocalRecords: @MainActor () -> Void = forgetLocalRecords) {
        guard !settings.bool(forKey: installedKey) else { return }
        forgetLocalRecords()
        if let left = invitation.read()?.inviterKeyID, !left.isEmpty, left == ownKeyID() { invitation.remove() }
        settings.set(true, forKey: installedKey)
    }

    /// This app's own records in its keychain: its lists, its keys and its rules.
    public static func forgetLocalRecords() {
        let app = Bundle.main.bundleIdentifier ?? "com.agentkeyring"
        for service in [app + ".lists.v3", app + ".keys.v3", app + ".rules.v2"] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        }
    }

    static let firstRunKey = "firstRun"

    /// The saved state, resumed. None saved, or none this build can read, starts first run at Welcome.
    static func savedFirstRun(_ settings: UserDefaults) -> MacFirstRunFlow {
        guard let data = settings.data(forKey: firstRunKey) else { return .welcome }
        do {
            return try MacFirstRunFlow.decodeProtobuf(data).restored
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "FirstRun").error("Saved first-run state was unreadable; starting at welcome: \(String(describing: error), privacy: .public)")
            return .welcome
        }
    }

    /// Moves first run on and saves where it is.
    public func sendFirstRunEvent(_ event: MacFirstRunEvent) {
        let next = firstRun.after(event)
        guard next != firstRun else { return }
        let previous = firstRun
        KeyringDiagnosticLog.mac.noteDeviceEvent("firstrun", "moved", ["from": firstRun.diagnosticName, "to": next.diagnosticName, "by": event.diagnosticName])
        firstRun = next
        settings.set(try? next.encodeProtobuf(), forKey: Self.firstRunKey)
        if previous.step == .welcome, next.step != .welcome, let device {
            device.mayLeaveInvitation = true
            device.leaveInvitation()
        }
    }

    /// Clears any displayed import/setup problem banner.
    public func clearProblem() {
        problem = nil
        importSession.sendSelectiveImportEvent(.clearProblem)
    }

    #if DEBUG
    /// Installs ephemeral software keys in unit tests without touching the system keychain or network.
    func installTestingKeys(_ testKeys: MacKeys) {
        keys = testKeys
        accessControl.actor = testKeys.deviceKeyID
        setup = .ready
    }
    #endif

    /// Drops the cached iCloud change token and re-pulls everything fresh.
    public func syncWithICloudNow() {
        device?.syncWithICloudNow()
    }

    /// Clears local Agent Keyring state on this Mac and returns to the first-run Welcome screen.
    /// When `includingICloud` is true, also deletes the AgentKeyringVault CloudKit zone and iCloud Keychain invitation
    /// BEFORE stopping the local device or tearing down local state so failures leave the app running.
    public func resetKeyring(includingICloud: Bool, invitation: CloudKeychainInvitationStore = MacSyncEnvironment.iCloudInvitationStore,
                      deleteCloudZone: (@Sendable () async throws -> Void)? = nil,
                      forgetLocalRecords: @MainActor () -> Void = MacKeyringEngine.forgetLocalRecords) async throws {
        if includingICloud {
            if let deleteCloudZone {
                try await deleteCloudZone()
            } else if let cloud = device?.cloudSync.cloud ?? CloudVault().map({ $0 as any CloudPipe }) {
                try await cloud.deleteCloudZone()
            }
            invitation.remove()
        }

        exportTimeout?.cancel()
        exportTimeout = nil
        categorySortingTask?.cancel()
        categorySortingTask = nil
        vaultCategorySortingTask?.cancel()
        vaultCategorySortingTask = nil
        startupTask?.cancel()
        startupTask = nil
        statusLoaded = false
        device?.stopBackgroundWork()

        if !includingICloud {
            device?.cloudSync.cloud?.forgetLocalCloudState()
            if let own = keys?.deviceKeyID, invitation.read()?.inviterKeyID == own {
                invitation.remove()
            }
        }

        forgetLocalRecords()
        try await store.deleteVaultFiles()
        try leaseStore.clearLeaseRecords()
        usage.clearUsageLog()
        accessControl.resetAccessRules()

        status = nil
        problem = nil
        leaseLogins = []
        sentList = nil
        testedAt = nil
        lastCopyChangedNothing = false
        automaticCopiesMissing = false
        localAutomaticCopyIDs = []
        publishingListSnapshot = nil
        automaticCopiesChecked = false
        importSession = SelectiveImportSession(path: .pickFew)
        practiceResults = [:]
        practiceTokens = [:]
        handledTokens = []
        settings.removeObject(forKey: Self.firstRunKey)
        settings.removeObject(forKey: Self.testedAtKey)
        firstRun = .welcome

        if let keys {
            adopt(keys, leavingInvitation: false)
        }
    }

    /// Send Practice Request on step 1: the practice panel appears beside the window, for this request.
    public func sendFirstRunPractice() {
        sendFirstRunEvent(.sendPractice(id: UUID()))
    }

    /// An agent on this Mac had its request answered: on "Connect an agent", that is the outcome he waits for.
    func noteAgentAnswered(lease leaseID: String, approved: Bool) {
        guard firstRun.step == .connectAgent(.notTried) else { return }
        sendFirstRunEvent(.agentAnswered(agent: leaseStore.requester(for: leaseID)?.name ?? MessageCopy.anAgent, approved: approved))
    }

    /// The last practice request on each device he answers on, by device key.
    public internal(set) var practiceResults: [String: PracticeResult] = [:]
    @ObservationIgnored private var practiceTokens: [String: UInt64] = [:]

    /// This Mac's key in `practiceResults`.
    public var thisMacDeviceKey: String { device?.ownDeviceID ?? "this-mac" }

    /// "Send Practice Request": on this Mac the practice panel appears beside
    /// the window; on another device it arrives like a real request, and the
    /// row shows how it was answered.
    public func sendPracticeRequest(to deviceKey: String) async {
        let token = (practiceTokens[deviceKey] ?? 0) &+ 1
        practiceTokens[deviceKey] = token
        practiceResults[deviceKey] = .sent
        guard let device, deviceKey != thisMacDeviceKey else { return }
        do {
            let lease = try await device.sendPracticeRequest(on: deviceKey) { [weak self] lease in
                guard let self, self.practiceTokens[deviceKey] == token, lease.state == .waiting else { return }
                self.practiceResults[deviceKey] = lease.pushedUnixSeconds > 0
                    ? .withApple(at: Date(timeIntervalSince1970: TimeInterval(lease.pushedUnixSeconds))) : .sent
            }
            guard practiceTokens[deviceKey] == token else { return }
            practiceResults[deviceKey] = switch lease.state {
            case .approved, .ended, .expired, .released: .approved(at: .now)
            case .denied: .denied(at: .now, reply: lease.reply)
            case .cancelled, .waiting, .unanswered, .unspecified, .UNRECOGNIZED: .unanswered
            }
        } catch {
            guard practiceTokens[deviceKey] == token else { return }
            practiceResults[deviceKey] = .failed((error as? LocalizedError)?.errorDescription ?? MessageCopy.somethingWentWrong)
        }
    }

    /// The practice here was answered: the request panel's backend says how.
    public func notePracticeHere(_ result: PracticeResult) {
        if practiceResults[thisMacDeviceKey] == .sent { practiceResults[thisMacDeviceKey] = result }
        switch result {
        case .approved: device?.answerDevicePractice(approved: true, reply: "")
        case let .denied(_, reply): device?.answerDevicePractice(approved: false, reply: reply)
        default: break
        }
    }

    /// A practice request is waiting on this Mac, outside first run's own.
    public var practiceWaitingHere: Bool { practiceResults[thisMacDeviceKey] == .sent }

    var currentRules: [UUID: LoginRule] {
        Dictionary(uniqueKeysWithValues: leaseLogins.map { ($0.id, localRule(for: $0.id)) })
    }

    /// The rule as it applies to agents on this Mac: Automatic runs without asking only when this Mac
    /// is still enrolled (or standalone) and already holds a current local Automatic copy.
    func localRule(for id: UUID) -> LoginRule {
        let rule = accessControl.rule(for: id)
        guard rule == .automatic else { return rule }
        return thisMacIsEnrolledMachine && localAutomaticCopyIDs.contains(id.uuidString) ? .automatic : .ask
    }

    /// The Mac's chip keys: the saved ones, or on a Mac with Touch ID made on
    /// first use. A Mac without Touch ID makes them only from setup (`usePasswordOnThisMac`).
    func macKeys() throws -> MacKeys {
        if let keys { return keys }
        guard setup.makesKeysItself else { throw MacKeysError.notMade }
        do {
            if let saved = try MacKeys.loadMacKeys() { return adopt(saved) }
            guard MacProbe.readMacProbe().hardware == .touchID else { throw MacKeysError.notMade }
            return adopt(try makeOrLoad(.biometricOrCompanion))
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Keys").error("This Mac's keys could not be made or read: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Josh's Touch ID (or this Mac's password) for `reason`, through this Mac's keys: software keys answer at once.
    public func confirmOwner(_ context: LAContext, reason: String, until deadline: Date = .now.addingTimeInterval(600)) async throws {
        try await macKeys().confirmOwner(context, reason: reason, until: deadline)
    }

    /// Makes keys, or if another launch saved some first, uses those.
    private func makeOrLoad(_ mode: MacApprovalMode) throws -> MacKeys {
        do { return try MacKeys.make(mode) } catch MacKeysError.alreadyMade {
            guard let saved = try MacKeys.loadMacKeys() else { throw MacKeysError.alreadyMade }
            return saved
        }
    }

    /// Finds this Mac's keys at launch, or works out what setup must ask first. Only while loading: once.
    func prepareKeys() {
        guard setup == .loading else { return }
        if keys != nil { return sendSetup(.keysMade) }
        let probe = MacProbe.readMacProbe()
        let saved: MacKeys?
        do { saved = try MacKeys.loadMacKeys() } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Keys").error("This Mac's keys could not be read: \(String(describing: error), privacy: .public)")
            return sendSetup(.keysFailed(MessageCopy.keysUnreadable(error)))
        }
        if let saved {
            adopt(saved)
            return
        }
        sendSetup(.looked(keysSaved: false, hardware: probe.hardware))
        // Touch ID off for now (lid shut, keyboard unplugged, no fingerprint): step 1 says why, and the keys are made on first use.
        guard setup == .ready, probe.biometry == nil else { return }
        do { _ = try macKeys() } catch { sendSetup(.keysFailed(MessageCopy.keysNotMade(error))) }
    }

    /// Moves setup on, as his choice on the setup window.
    public func sendSetup(_ event: MacHardwareSetupEvent) {
        let next = setup.after(event)
        guard next != setup else { return }
        KeyringDiagnosticLog.mac.noteDeviceEvent("setup", "moved", ["from": "\(setup)", "to": "\(next)", "by": "\(event)"])
        setup = next
        if setup == .loading { prepareKeys() }
    }

    /// "Use My Mac Password": makes this Mac's keys, opened with its password, then first run starts.
    /// If a Touch ID keyboard was connected while he read the page, the keys are Touch ID keys instead:
    /// they never change, so they are made for the best this Mac has.
    public func usePasswordOnThisMac() {
        guard case .personalMac = setup, keys == nil else { return }
        var unusable: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &unusable) else {
            return sendSetup(.keysFailed(MessageCopy.noMacPassword))
        }
        let mode: MacApprovalMode = MacProbe.readMacProbe().biometry == nil ? .biometricOrCompanion : .devicePassword
        do {
            adopt(try makeOrLoad(mode))
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Keys").error("Password-mode keys could not be made: \(String(describing: error), privacy: .public)")
            sendSetup(.keysFailed(MessageCopy.keysNotMade(error)))
        }
    }

    @discardableResult
    package func adopt(_ made: MacKeys, environment customEnvironment: MacSyncEnvironment? = nil, leavingInvitation: Bool? = nil) -> MacKeys {
        keys = made
        accessControl.actor = made.deviceKeyID
        let environment: MacSyncEnvironment
        if let customEnvironment {
            environment = customEnvironment
        } else {
            var built = MacSyncEnvironment(storage: .app())
            built.cloud = CloudVault()
            environment = built
        }
        device = MacSyncCoordinator(keys: made, store: store, leaseStore: leaseStore, environment: environment) { [weak self] in
            try await self?.catalogueLogins() ?? []
        }
        device?.onPeerVault = { [weak self] vault in await self?.foldPeerVault(vault) ?? true }
        if let pushAddress { device?.registerPush(token: pushAddress.token, topic: pushAddress.topic, production: pushAddress.production) }
        device?.ownVault = { [weak self] in await self?.ownVault() }
        // Another device's list is kept beside this Mac's: its rules are merged in, and Devices offers to send the merged list.
        device?.onCatalogueConflict = { KeyringDiagnosticLog.mac.noteDeviceEvent("cloud", "merged-list-unsent", [:]) }
        device?.secretDeletedHere = { [weak self] loginID in
            self?.leaseLogins.contains { $0.id.uuidString == loginID && $0.isSecretDeleted } == true
        }
        device?.onCatalogue = { [weak self] catalogue, base in try await self?.adoptCatalogue(catalogue, base: base) }
        device?.onPublished = { [weak self] in
            self?.recordSentList()
            await self?.noteMissingAutomaticCopies()
        }
        device?.onPracticeHere = { [weak self] in
            guard let self else { return }
            Task { await self.sendPracticeRequest(to: self.thisMacDeviceKey) }
        }
        device?.onAutomaticCopiesChanged = { [weak self] in
            await self?.noteMissingAutomaticCopies()
        }
        device?.startBackgroundWork(leavingInvitation: leavingInvitation ?? (firstRun.step != .welcome))
        sendSetup(.keysMade)
        return made
    }

    public func loadStatus() async {
        if let startupTask {
            await startupTask.value
            return
        }
        if statusLoaded { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startupTask = nil }
            await self.performLoadStatus()
            self.statusLoaded = true
        }
        startupTask = task
        await task.value
    }

    private func performLoadStatus() async {
        defer { isLoading = false }
        do {
            let importedMetadata = try await store.loadCurrentMetadata()
            status = importedMetadata?.safeStatus
            leaseLogins = importedMetadata?.candidates ?? []
            await accessControl.refresh(fromMetadata: importedMetadata)
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Import").error("Loading failed: \(String(describing: error), privacy: .public)")
            problem = MessageCopy.copyUnreadable
            prepareKeys()
            return
        }
        prepareKeys()
        // Blocked deletes the secret: a deletion that failed last time is tried again.
        let blockedWithSecret = Set(leaseLogins.filter { accessControl.rule(for: $0.id) == .blocked && !$0.isSecretDeleted }.map(\.id))
        await deleteSecretsOrReport(of: blockedWithSecret)
        await noteMissingAutomaticCopies()
        sortUnlistedVaultLoginsIfNeeded()
    }

}
#endif
