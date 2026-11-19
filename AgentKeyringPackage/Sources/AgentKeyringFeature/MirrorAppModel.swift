import AgentKeyringProtocol
import AppKit
import AuthenticationServices
import Foundation
import Observation
import OSLog

public enum MirrorNoticeKind: Equatable, Sendable {
    case information
    case warning
    case error
}

public struct MirrorNotice: Equatable, Sendable {
    public let kind: MirrorNoticeKind
    public let text: String

    public init(kind: MirrorNoticeKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

@available(macOS 26.0, *)
@MainActor
@Observable
public final class MirrorAppModel {
    public internal(set) var status: SafeMirrorStatus?
    public private(set) var isLoading = true
    public internal(set) var notice: MirrorNotice?
    public let accessControl: CredentialAccessController
    public var syncReminders: MirrorSyncReminders?

    let store: LoginStore
    let mapper: CredentialExchangeMapper
    let credentialImporter: any CredentialImporting
    let merger: SnapshotMerger
    public let leaseStore: CredentialLeaseStore
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

    static let firstRunKey = "firstRun"
    static let firstRunFinishedKey = "firstRunFinished"
    static let agentsSetUpKey = "agentsSetUp"

    /// The saved state, resumed. A Mac that finished first run before it was
    /// saved this way, or whose saved state a later build cannot read, is never stuck.
    static func savedFirstRun(_ settings: UserDefaults) -> FirstRun {
        if let data = settings.data(forKey: firstRunKey), let saved = try? JSONDecoder().decode(FirstRun.self, from: data) {
            return saved.resumed
        }
        return settings.bool(forKey: firstRunFinishedKey) || settings.object(forKey: testedAtKey) != nil ? .finished : .welcome
    }

    /// Moves first run on, as the board draws it, and saves where it is.
    public func send(_ event: FirstRun.Event) {
        let next = firstRun.after(event).settled(agentsSetUp: settings.bool(forKey: Self.agentsSetUpKey))
        guard next != firstRun else { return }
        firstRun = next
        settings.set(try? JSONEncoder().encode(next), forKey: Self.firstRunKey)
    }

    /// `agent-keyring install` ran on this Mac.
    func noteAgentsSetUp() {
        settings.set(true, forKey: Self.agentsSetUpKey)
        send(.agentsSetUp)
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
            notice = MirrorNotice(kind: .error, text: "Agent Keyring's copy of your passwords could not be opened. Passwords was not changed.")
            return
        }
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        if (try? macKeys()) != nil { device?.start() }
    }

}
