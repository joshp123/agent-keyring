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
    /// This Mac on the relay, once its keys exist. Nil when the Mac has no Secure Enclave.
    public private(set) var device: MacDevice?
    @ObservationIgnored private var keys: MacKeys?
    /// A new import changed the logins the other devices hold; Josh hasn't yet allowed sending them.
    public internal(set) var importedLoginsAwaitApproval = false
    var isApprovingLease = false
    public internal(set) var leaseLogins: [CredentialCandidate] = []
    let bridge: AgentBridgeDirectory
    /// When this Mac last passed its practice request: Touch ID, its chip keys and sealing work.
    public internal(set) var testedAt: Date?
    /// Where first run is (FirstRun.swift); saved, so a restart resumes it.
    public private(set) var firstRun: FirstRun
    /// "Copy your passwords", from first run or the main window; nil when no
    /// copy is open. The main window shows it in place of the list while it is set.
    public internal(set) var passwordsCopy: PasswordsCopy? {
        didSet { if passwordsCopy != oldValue { DiagnosticLog.record("copy", "moved", ["to": passwordsCopy.map { "\($0)" } ?? "closed"]) } }
    }
    @ObservationIgnored var exportTimeout: Task<Void, Never>?
    /// This Mac's Automatic switch while it is not joined to a relay; once
    /// joined, its entry in the members list decides.
    var savedAutomaticOnThisMac: Bool {
        didSet { settings.set(savedAutomaticOnThisMac, forKey: Self.automaticOnThisMacKey) }
    }
    /// He clicked Done at the end of first run. Until then the window opens at launch.
    public var firstRunFinished: Bool { firstRun == .finished }
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
        leaseStore.onDecision = { [usage] id, login, event in usage.note(event, request: id, login: login) }
        savedAutomaticOnThisMac = settings.bool(forKey: Self.automaticOnThisMacKey)
        testedAt = settings.object(forKey: Self.testedAtKey) as? Date
        firstRun = Self.savedFirstRun(settings)
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
        for service in [app + ".relay.v2", app + ".rules.v2"] {
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
    /// saved this way, or whose saved state a later build cannot read, is never stuck.
    static func savedFirstRun(_ settings: UserDefaults) -> FirstRun {
        if let data = settings.data(forKey: firstRunKey), let saved = try? JSONDecoder().decode(FirstRun.self, from: data) {
            return saved
        }
        return settings.bool(forKey: firstRunFinishedKey) || settings.object(forKey: testedAtKey) != nil ? .finished : .welcome
    }

    /// Moves first run on, as the board draws it, and saves where it is.
    public func send(_ event: FirstRun.Event) {
        let next = firstRun.after(event, facts: firstRunFacts)
        guard next != firstRun else { return }
        DiagnosticLog.record("firstrun", "moved", ["from": "\(firstRun)", "to": "\(next)", "by": "\(event)"])
        firstRun = next
        settings.set(try? JSONEncoder().encode(next), forKey: Self.firstRunKey)
        // A step that finished while he is in another app: the Dock icon bounces
        // once, and the window waits behind; it is never pushed in front.
        if !NSApplication.shared.isActive, [.deviceDone, .connected].contains(event) || { if case .imported = event { true } else { false } }() {
            NSApplication.shared.requestUserAttention(.informationalRequest)
        }
        Task { await reportStatus() }
        if firstRun.devices?.iPhone == true { device?.leaveNameForIPhone() }
    }

    /// What the world says is already done, for the journey to pass over.
    var firstRunFacts: FirstRun.Facts {
        let devices = device?.members?.devices ?? []
        let report = devices.first { $0.kind == .iphone }.flatMap { device?.reports[$0.keyID] }
        return FirstRun.Facts(alwaysOn: device?.isJoined == true,
            iPhoneDone: report?.finished == true,
            // Apple Watch reports through the iPhone: adding it is the iPhone's WATCH step.
            watchDone: devices.contains { $0.kind == .watch } || report?.step == .ready)
    }

    /// The iPhone finished its first run, or the Apple Watch joined: the Mac's window for it moves on.
    func noteDevicesChanged() {
        send(.deviceDone)
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

    /// "Try it now": the first request from an agent on this Mac that he
    /// approved, as (agent, site); nil until there is one. Read from the leases.
    public var firstApprovedRequest: (agent: String, site: String)? {
        guard let lease = leaseStore.leases.filter({ $0.approvedAtUnixSeconds > 0 && $0.approvedBy != .automaticRule })
            .min(by: { $0.approvedAtUnixSeconds < $1.approvedAtUnixSeconds }) else { return nil }
        let site = lease.sites.first.map { URL(string: $0)?.host ?? $0 } ?? "a website"
        return (leaseStore.requester(for: lease.leaseID)?.name ?? "An agent", site)
    }


    /// "Done": the first-run window closes and the main window takes its place.
    public func finishFirstRun() {
        send(.done)
    }

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
        device = MacDevice(keys: made, store: store) { [weak self] in try await self?.catalogueLogins() ?? [] }
        device?.onCatalogue = { [weak self] catalogue, mine in await self?.adoptCatalogue(catalogue, ownCopies: mine) }
        device?.onStoppedOnDevice = { [weak self] leaseID in _ = try? self?.leaseStore.revoke(leaseID) }
        device?.onDevicesChanged = { [weak self] in self?.noteDevicesChanged() }
        device?.onOtherComputersRequest = { [weak self] id, login, event in self?.usage.note(event, request: id, login: login) }
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
        try? leaseStore.reconcile(logins: leaseLogins + [PracticePassword.candidate], policies: currentPolicies)
        if (try? macKeys()) != nil {
            device?.start()
            if firstRun.devices?.iPhone == true { device?.leaveNameForIPhone() }
        }
    }

}
