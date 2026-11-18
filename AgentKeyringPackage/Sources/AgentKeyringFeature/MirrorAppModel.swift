import AgentKeyringProtocol
import AppKit
import AuthenticationServices
import Foundation
import Observation
import OSLog

public enum ProviderEnablementState: Equatable, Sendable {
    case unknown
    case requesting
    case enabled
    case denied
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
    public private(set) var includeExampleCredential: Bool
    public internal(set) var selfTest = MacSelfTest.notRun
    /// From Open Passwords until the logins arrive: the window stays above Passwords.
    public internal(set) var awaitingExport = false
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
        self.includeExampleCredential = settings.object(forKey: "includeExampleCredential") as? Bool ?? true
        if let tested = settings.object(forKey: Self.testedAtKey) as? Date { selfTest = .passed(tested) }
        accessControl.beforeSave = { [weak self] old, new, context in
            try await self?.applyRuleChange(from: old, to: new, context: context)
        }
        accessControl.onRulesChanged = { [weak self] in
            guard let self else { return }
            try? self.leaseStore.reconcile(logins: self.leaseLogins, policies: self.currentPolicies)
        }
    }

    var currentPolicies: [UUID: CredentialAccessPolicy] {
        Dictionary(uniqueKeysWithValues: leaseLogins.map { ($0.id, accessControl.policy(for: $0.id)) })
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
        return made
    }

    public func loadStatus() async {
        defer { isLoading = false }
        do {
            let importedMetadata = try await store.loadCurrentMetadata()
            status = importedMetadata?.safeStatus
            leaseLogins = metadataIncludingExample(importedMetadata)?.candidates ?? []
            await accessControl.refresh(fromMetadata: metadataIncludingExample(importedMetadata))
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Import").error("Loading failed: \(String(describing: error), privacy: .public)")
            notice = MirrorNotice(kind: .error, text: "Agent Keyring's saved logins could not be opened. Apple Passwords was not changed.")
            return
        }
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        // The chip keys can be made only while the Mac is unlocked; until then
        // this runs again at the next request or launch.
        try? await sealExampleIfNeeded()
        if (try? macKeys()) != nil { device?.start() }
        offerSelfTestIfNeeded()
    }

    public func setIncludeExampleCredential(_ enabled: Bool) async {
        includeExampleCredential = enabled
        settings.set(enabled, forKey: "includeExampleCredential")
        await loadStatus()
    }
}
