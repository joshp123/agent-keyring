import AgentKeyringProtocol
import AppKit
import AuthenticationServices
import Foundation
import Observation
import OSLog
import Security

@available(macOS 26.0, *)
@MainActor
@Observable
public final class MirrorAppModel {
    public internal(set) var status: SafeMirrorStatus?
    public private(set) var isLoading = true
    /// What went wrong, for the window to show; nil once it is put right.
    public internal(set) var problem: String?
    public let accessControl: CredentialAccessController
    public var syncReminders: MirrorSyncReminders?

    let store: LoginStore
    let mapper: CredentialExchangeMapper
    let credentialImporter: any CredentialImporting
    let merger: SnapshotMerger
    public let leaseStore: CredentialLeaseStore
    /// How often each password was asked for, approved and denied.
    public let usage = PasswordUsageLog()
    /// This Mac as the place the lists live and its door, once its keys exist. Nil when the Mac has no Secure Enclave.
    public private(set) var device: MacDevice?
    @ObservationIgnored private var keys: MacKeys?
    /// After a copy from Passwords changed the list and other devices hold the
    /// earlier one: the panel asks him to send the changes. Not saved: what is
    /// unsent is (`unsentChanges`), and the panel shows only after a copy.
    public internal(set) var resyncAsked = false
    /// The list the other devices last received (MirrorResync.swift); saved on every change.
    public internal(set) var sentList: [String: Date?]? {
        didSet { Self.saveSentList(sentList, in: settings) }
    }
    /// A password became Automatic on the iPhone, and a computer allowed Automatic passwords has no copy of it yet.
    public internal(set) var automaticCopiesMissing = false
    var isApprovingLease = false
    public internal(set) var leaseLogins: [CredentialCandidate] = []
    let bridge: AgentBridgeDirectory
    /// When this Mac last passed its practice request: Touch ID, its Secure Enclave keys and sealing work.
    public internal(set) var testedAt: Date?
    /// Where first run is (FirstRun.swift); saved, so a restart resumes it.
    public private(set) var firstRun: FirstRun
    /// "Copy your passwords", from first run or the main window; nil when no
    /// copy is open. The main window shows it in place of the list while it is set.
    public internal(set) var passwordsCopy: PasswordsCopy? {
        didSet { if passwordsCopy != oldValue { DiagnosticLog.record("copy", "moved", ["to": passwordsCopy.map { "\($0)" } ?? "closed"]) } }
    }
    @ObservationIgnored var exportTimeout: Task<Void, Never>?
    /// Which of the copy guide's five steps he is reading. He moves it; nothing else does.
    public var copyGuideStep = 1 {
        didSet { copyGuideStep = min(max(copyGuideStep, 1), 5) }
    }
    /// This Mac's Automatic switch while nothing has joined it; after that,
    /// its entry in the members list decides.
    var savedAutomaticOnThisMac: Bool {
        didSet { settings.set(savedAutomaticOnThisMac, forKey: Self.automaticOnThisMacKey) }
    }
    /// He clicked Show Passwords at the end of first run. Until then the window opens at launch.
    public var firstRunFinished: Bool { firstRun.step == .finished }
    let settings: UserDefaults
    var handledTokens = Set<UUID>()
    var agentListener: AgentBridgeServer?

    public init(
        store: LoginStore = LoginStore(),
        credentialImporter: any CredentialImporting = SystemCredentialImporter(),
        mapper: CredentialExchangeMapper = CredentialExchangeMapper(),
        merger: SnapshotMerger = SnapshotMerger(),
        bridge: AgentBridgeDirectory = AgentBridgeDirectory(),
        accessControl: CredentialAccessController = CredentialAccessController(),
        leaseStore: CredentialLeaseStore = CredentialLeaseStore(),
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
        savedAutomaticOnThisMac = settings.bool(forKey: Self.automaticOnThisMacKey)
        testedAt = settings.object(forKey: Self.testedAtKey) as? Date
        firstRun = Self.savedFirstRun(settings)
        sentList = Self.savedSentList(settings)
        leaseStore.onDecision = { [usage, weak self] id, login, event in
            usage.note(event, request: id, login: login)
            guard event != .asked else { return }
            // After the store has saved the lease, so its requester is there to name.
            Task { @MainActor in self?.noteAgentAnswered(lease: id, approved: event == .approved) }
        }
        accessControl.beforeSave = { [weak self] old, new, context in
            try await self?.applyRuleChange(from: old, to: new, context: context)
        }
        accessControl.onRulesChanged = { [weak self] in
            guard let self else { return }
            try? self.leaseStore.reconcile(logins: self.leaseLogins, policies: self.currentPolicies)
        }
    }

    static let installedKey = "installed"

    /// A fresh container is a new install: what a previous one left in the
    /// keychain (its relay and members, its rules, the name it left for the
    /// iPhone) goes, so first run starts from Welcome with nothing behind it.
    /// This Mac's own keys stay. Call before the model is made.
    public static func forgetPreviousInstall(settings: UserDefaults = .standard) {
        guard !settings.bool(forKey: installedKey) else { return }
        let app = Bundle.main.bundleIdentifier ?? "com.agentkeyring"
        for service in [app + ".relay.v2", app + ".lists.v2", app + ".rules.v2"] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.joshpalmer.AgentKeyring.invitation",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny, kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        settings.set(true, forKey: installedKey)
    }

    static let firstRunKey = "firstRun"
    static let firstRunFinishedKey = "firstRunFinished"

    /// The saved state, resumed. A Mac that finished first run before it was
    /// saved this way is never stuck; a state an earlier build saved (its
    /// journey of devices) starts first run again at Welcome.
    static func savedFirstRun(_ settings: UserDefaults) -> FirstRun {
        if let data = settings.data(forKey: firstRunKey) {
            return (try? JSONDecoder().decode(FirstRun.self, from: data))?.restored ?? .welcome
        }
        return settings.bool(forKey: firstRunFinishedKey) || settings.object(forKey: testedAtKey) != nil ? .finished : .welcome
    }

    /// Moves first run on and saves where it is.
    public func send(_ event: FirstRun.Event) {
        let next = firstRun.after(event)
        guard next != firstRun else { return }
        DiagnosticLog.record("firstrun", "moved", ["from": "\(firstRun)", "to": "\(next)", "by": "\(event)"])
        firstRun = next
        settings.set(try? JSONEncoder().encode(next), forKey: Self.firstRunKey)
    }

    /// Send Practice Request on step 1: the practice panel appears beside the window, for this request.
    public func sendFirstRunPractice() {
        send(.sendPractice(id: UUID()))
    }

    /// An agent on this Mac had its request answered: on "Connect an agent", that is the outcome he waits for.
    func noteAgentAnswered(lease leaseID: String, approved: Bool) {
        guard firstRun.step == .connectAgent(.notTried) else { return }
        send(.agentAnswered(agent: leaseStore.requester(for: leaseID)?.name ?? MessageCopy.anAgent, approved: approved))
    }

    /// The last practice request on each device he answers on, by device key.
    public internal(set) var practiceResults: [String: PracticeResult] = [:]

    /// This Mac's key in `practiceResults`.
    public var thisMacDeviceKey: String { device?.ownDeviceID ?? "this-mac" }

    /// "Send Practice Request": on this Mac the practice panel appears beside
    /// the window; on another device it arrives like a real request, and the
    /// row shows how it was answered.
    public func sendPractice(to deviceKey: String) async {
        practiceResults[deviceKey] = .sent
        guard let device, deviceKey != thisMacDeviceKey else { return }
        do {
            let lease = try await device.practice(on: deviceKey) { [weak self] lease in
                guard lease.state == .waiting else { return }
                self?.practiceResults[deviceKey] = lease.arrivedUnixSeconds > 0
                    ? .arrived(at: Date(timeIntervalSince1970: TimeInterval(lease.arrivedUnixSeconds)), on: lease.arrivedOn)
                    : lease.pushedUnixSeconds > 0 ? .withApple(at: Date(timeIntervalSince1970: TimeInterval(lease.pushedUnixSeconds))) : .sent
            }
            practiceResults[deviceKey] = switch lease.state {
            case .approved, .ended: .approved(at: .now)
            case .denied: .denied(at: .now, reply: lease.reply)
            default: .unanswered
            }
        } catch {
            practiceResults[deviceKey] = .failed((error as? LocalizedError)?.errorDescription ?? MessageCopy.somethingWentWrong)
        }
    }

    /// The practice here was answered: the request panel's backend says how.
    public func notePracticeHere(_ result: PracticeResult) {
        if practiceResults[thisMacDeviceKey] == .sent { practiceResults[thisMacDeviceKey] = result }
    }

    /// A practice request is waiting on this Mac, outside first run's own.
    public var practiceWaitingHere: Bool { practiceResults[thisMacDeviceKey] == .sent }

    var currentPolicies: [UUID: CredentialAccessPolicy] {
        Dictionary(uniqueKeysWithValues: leaseLogins.map { ($0.id, localPolicy(for: $0.id)) })
    }

    /// The rule as it applies to agents on this Mac: Automatic asks while
    /// this Mac is not one of the computers allowed Automatic passwords.
    func localPolicy(for id: UUID) -> CredentialAccessPolicy {
        let policy = accessControl.policy(for: id)
        return policy == .allowAutomatically && !automaticOnThisMac ? .ask : policy
    }

    /// The Mac's chip keys, made on first use.
    func macKeys() throws -> MacKeys {
        if let keys { return keys }
        let made: MacKeys
        do { made = try MacKeys() } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Keys").error("This Mac's keys could not be made or read: \(String(describing: error), privacy: .public)")
            throw error
        }
        keys = made
        #if DEBUG
        let storage = MacStorage.app(standIn: made.standIn)
        #else
        let storage = MacStorage.app(standIn: false)
        #endif
        device = MacDevice(keys: made, store: store, leaseStore: leaseStore, environment: MacDevice.Environment(storage: storage)) { [weak self] in
            try await self?.catalogueLogins() ?? []
        }
        device?.onCatalogue = { [weak self] catalogue, mine in await self?.adoptCatalogue(catalogue, ownCopies: mine) }
        device?.onPublished = { [weak self] in self?.recordSentList() }
        device?.onPracticeHere = { [weak self] in
            guard let self else { return }
            Task { await self.sendPractice(to: self.thisMacDeviceKey) }
        }
        return made
    }

    public func loadStatus() async {
        defer { isLoading = false }
        do {
            let importedMetadata = try await store.loadCurrentMetadata()
            status = importedMetadata?.safeStatus
            leaseLogins = importedMetadata?.candidates ?? []
            await accessControl.refresh(fromMetadata: importedMetadata)
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Import").error("Loading failed: \(String(describing: error), privacy: .public)")
            problem = MessageCopy.copyUnreadable
            return
        }
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        if (try? macKeys()) != nil { device?.start() }
        seedSentList()
    }

}
