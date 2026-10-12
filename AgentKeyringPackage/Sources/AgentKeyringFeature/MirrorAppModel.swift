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

    let staleLogins: PossiblyStaleLogins
    public var syncReminders: MirrorSyncReminders?

    let store: EncryptedSnapshotStore
    let mapper: CredentialExchangeMapper
    let credentialImporter: any CredentialImporting
    let merger: SnapshotMerger
    let resolver: CredentialResolver
    public let grants = CredentialApprovalGrants()
    let approvals: CredentialApprovalCoordinator
    public let approvalRoutingSettings: ApprovalRoutingSettings
    let authorizer: any CredentialReleaseAuthorizing
    let bridge: AgentBridgeDirectory
    public private(set) var includeExampleCredential: Bool
    private let settings: UserDefaults
    var handledTokens = Set<UUID>()
    var handledAgentRequests = Set<UUID>()

    public init(
        store: EncryptedSnapshotStore = EncryptedSnapshotStore(),
        credentialImporter: any CredentialImporting = SystemCredentialImporter(),
        mapper: CredentialExchangeMapper = CredentialExchangeMapper(),
        merger: SnapshotMerger = SnapshotMerger(),
        resolver: CredentialResolver = CredentialResolver(),
        authorizer: any CredentialReleaseAuthorizing = LocalCredentialReleaseAuthorizer(),
        bridge: AgentBridgeDirectory = AgentBridgeDirectory(),
        accessControl: CredentialAccessController = CredentialAccessController(),
        phoneChannel: (any IPhoneApprovalChannel)? = nil,
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
        self.settings = settings
        let routingSettings = ApprovalRoutingSettings(defaults: settings)
        self.approvalRoutingSettings = routingSettings
        self.approvals = CredentialApprovalCoordinator(phoneChannel: phoneChannel,
            pairedDevices: accessControl,
            phoneDelay: { TimeInterval(routingSettings.phoneDelaySeconds) })
        self.staleLogins = PossiblyStaleLogins(settings: settings)
        self.includeExampleCredential = settings.object(forKey: "includeExampleCredential") as? Bool ?? true
    }

    public func loadStatus() async {
        defer { isLoading = false }
        do {
            let importedMetadata = try await store.loadCurrentMetadata()
            status = importedMetadata?.safeStatus
            await accessControl.refresh(fromMetadata: metadataIncludingExample(importedMetadata))
        } catch {
            notice = MirrorNotice(
                kind: .error,
                text: "The encrypted mirror could not be opened. Apple Passwords was not changed."
            )
        }
    }

    public func setIncludeExampleCredential(_ enabled: Bool) async {
        includeExampleCredential = enabled
        settings.set(enabled, forKey: "includeExampleCredential")
        await loadStatus()
    }
}
