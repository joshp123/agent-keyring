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
    public let fillAccessibility: FillAccessibilityOnboarding

    let staleLogins: PossiblyStaleLogins
    public var syncReminders: MirrorSyncReminders?

    let store: EncryptedSnapshotStore
    let mapper: CredentialExchangeMapper
    let credentialImporter: any CredentialImporting
    let merger: SnapshotMerger
    let resolver: CredentialResolver
    public let leaseStore: CredentialLeaseStore
    @ObservationIgnored public lazy var relayApprover: RelayApprover = makeRelayApprover()
    public var automaticallyPromptForLeases = true
    var macApprovalTask: Task<Void, Never>?
    var isApprovingLease = false
    var attemptedMacApprovals = Set<String>()
    public internal(set) var leaseLogins: [CredentialCandidate] = []
    public let approvalRoutingSettings: ApprovalRoutingSettings
    let authorizer: any CredentialReleaseAuthorizing
    let bridge: AgentBridgeDirectory
    public private(set) var includeExampleCredential: Bool
    private let settings: UserDefaults
    var handledTokens = Set<UUID>()
    var agentListener: AgentBridgeServer?
    public internal(set) var lastAgentActivity: AgentRequestActivity?

    public init(
        store: EncryptedSnapshotStore = EncryptedSnapshotStore(),
        credentialImporter: any CredentialImporting = SystemCredentialImporter(),
        mapper: CredentialExchangeMapper = CredentialExchangeMapper(),
        merger: SnapshotMerger = SnapshotMerger(),
        resolver: CredentialResolver = CredentialResolver(),
        authorizer: any CredentialReleaseAuthorizing = LocalCredentialReleaseAuthorizer(),
        bridge: AgentBridgeDirectory = AgentBridgeDirectory(),
        accessControl: CredentialAccessController = CredentialAccessController(),
        fillAccessibility: FillAccessibilityOnboarding = FillAccessibilityOnboarding(),
        leaseStore: CredentialLeaseStore = CredentialLeaseStore(),
        settings: UserDefaults = .standard
    ) {
        self.store = store
        self.credentialImporter = credentialImporter
        self.mapper = mapper
        self.merger = merger
        self.resolver = resolver
        self.authorizer = authorizer
        self.bridge = bridge
        self.accessControl = accessControl
        self.fillAccessibility = fillAccessibility
        self.settings = settings
        let routingSettings = ApprovalRoutingSettings(defaults: settings)
        self.approvalRoutingSettings = routingSettings
        self.leaseStore = leaseStore
        self.staleLogins = PossiblyStaleLogins(settings: settings)
        self.includeExampleCredential = settings.object(forKey: "includeExampleCredential") as? Bool ?? true
        self.accessControl.connectAuthority(leaseStore, authorize: { [weak self] context, reason in
            guard let self else { throw CancellationError() }
            try self.relayApprover.load()
            if self.relayApprover.state.keySet != nil {
                try await self.relayApprover.keys().1.authorize(context: context, reason: reason)
            }
        }, commit: { [weak self] policies, rules, context in
            guard let self else { throw CancellationError() }
            let imported = try await self.store.loadCurrent()
            guard let generation = self.generationIncludingExample(imported) else {
                throw LeaseFailure(.unavailable, "The saved logins could not be opened.")
            }
            try Task.checkCancellation()
            try self.relayApprover.applyConfirmedRules(RelayApproverVault(generation: generation, policies: policies),
                context: context, rules: rules)
        })
        self.accessControl.onRulesChanged = { [weak self] in
            guard let self else { return }
            self.relayApprover.noteRulesChanged()
            do {
                try self.leaseStore.reconcile(logins: self.leaseLogins,
                    policies: Dictionary(uniqueKeysWithValues: self.leaseLogins.map { ($0.id, self.accessControl.policy(for: $0.id)) }),
                    rulesConfirmed: !self.accessControl.needsConfirmation)
            } catch {
                if !self.leaseStore.needsHistoryReset {
                    self.notice = MirrorNotice(kind: .error, text: "Lease access could not be updated. New deliveries will check the saved rules.")
                }
            }
        }
    }

    public func loadStatus() async {
        defer { isLoading = false }
        do {
            let importedMetadata = try await store.loadCurrentMetadata()
            status = importedMetadata?.safeStatus
            leaseLogins = metadataIncludingExample(importedMetadata)?.candidates ?? []
            await accessControl.refresh(fromMetadata: metadataIncludingExample(importedMetadata))
        } catch {
            notice = MirrorNotice(
                kind: .error,
                text: "The encrypted mirror could not be opened. Apple Passwords was not changed."
            )
            return
        }
        do { try await refreshLeasePolicy() }
        catch { /* The rules and task-history screens show their own recovery action. */ }
        relayApprover.start()
    }

    public func setIncludeExampleCredential(_ enabled: Bool) async {
        includeExampleCredential = enabled
        settings.set(enabled, forKey: "includeExampleCredential")
        await loadStatus()
    }
}
