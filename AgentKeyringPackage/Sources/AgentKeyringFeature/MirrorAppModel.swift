import AgentKeyringProtocol
import AppKit
import AuthenticationServices
import Foundation
import Observation
import OSLog

/// AutoFill from Agent Keyring, which macOS may want on before Passwords
/// lists the app as an export destination. First run asks only from its link.
public enum ProviderEnablementState: Equatable, Sendable {
    case unknown
    /// macOS's question "Turn on AutoFill from “Agent Keyring”?" is up.
    case requesting
    case enabled
    /// He answered Not Now.
    case notNow
}

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
    public internal(set) var isImporting = false
    public internal(set) var providerState = ProviderEnablementState.unknown
    /// He clicked "Agent Keyring isn't in the list?" and has not yet turned AutoFill on.
    public internal(set) var showsAutoFillHelp = false
    /// macOS answers a second request only 10 seconds after the last one.
    public internal(set) var canAskAgain = true
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
    public internal(set) var selfTest = MacSelfTest.notRun
    /// From Open Passwords until the logins arrive: the window stays above Passwords.
    public internal(set) var awaitingExport = false {
        didSet { if !awaitingExport { exportTimeout?.cancel(); exportTimeout = nil } }
    }
    @ObservationIgnored var exportTimeout: Task<Void, Never>?
    /// Five minutes after Open Passwords, nothing has arrived.
    public internal(set) var exportTimedOut = false
    /// This Mac's Automatic switch while it is not joined to a relay; once
    /// joined, its entry in the members list decides.
    var savedAutomaticOnThisMac: Bool {
        didSet { settings.set(savedAutomaticOnThisMac, forKey: Self.automaticOnThisMacKey) }
    }
    /// He clicked Done at the end of first run. Until then the window opens at launch.
    public private(set) var firstRunFinished: Bool
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
        // A Mac that passed the old test request before first run had a Done finished it then.
        savedAutomaticOnThisMac = settings.bool(forKey: Self.automaticOnThisMacKey)
        firstRunFinished = settings.bool(forKey: Self.firstRunFinishedKey) || settings.object(forKey: Self.testedAtKey) != nil
        if let tested = settings.object(forKey: Self.testedAtKey) as? Date { selfTest = .passed(tested) }
        accessControl.beforeSave = { [weak self] old, new, context in
            try await self?.applyRuleChange(from: old, to: new, context: context)
        }
        accessControl.onRulesChanged = { [weak self] in
            guard let self else { return }
            try? self.leaseStore.reconcile(logins: self.leaseLogins, policies: self.currentPolicies)
        }
    }

    static let firstRunFinishedKey = "firstRunFinished"

    /// "Done": the first-run window closes and the main window takes its place.
    public func finishFirstRun() {
        firstRunFinished = true
        settings.set(true, forKey: Self.firstRunFinishedKey)
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
        device = MacDevice(keys: made, store: store) { [weak self] in self?.catalogueLogins() ?? [] }
        device?.onCatalogue = { [weak self] catalogue, mine in await self?.adoptCatalogue(catalogue, ownCopies: mine) }
        device?.onStoppedOnDevice = { [weak self] leaseID in _ = try? self?.leaseStore.end(leaseID) }
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
        offerSelfTestIfNeeded()
    }

}
