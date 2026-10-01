import AppKit
import AuthenticationServices
import Foundation
import Observation
import OSLog

private let credentialExchangeLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "CredentialExchange"
)

private let agentBridgeLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "AgentBridge"
)

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
    public private(set) var status: SafeMirrorStatus?
    public private(set) var isLoading = true
    public private(set) var isImporting = false
    public private(set) var providerState = ProviderEnablementState.unknown
    public private(set) var notice: MirrorNotice?
    public private(set) var pendingCredentialRelease: CredentialReleaseAuthorizationRequest?
    public let accessControl: CredentialAccessController

    private let store: EncryptedSnapshotStore
    private let mapper: CredentialExchangeMapper
    private let credentialImporter: any CredentialImporting
    private let merger: SnapshotMerger
    private let resolver: CredentialResolver
    private let authorizer: any CredentialReleaseAuthorizing
    private let bridge: AgentBridgeDirectory
    private let pasteboard: ExpiringPasteboard
    private let approvalWindowPresenter: ApprovalWindowPresenter
    private let includeExampleCredential: Bool
    private var handledTokens = Set<UUID>()
    private var handledAgentRequests = Set<UUID>()

    public init(
        store: EncryptedSnapshotStore = EncryptedSnapshotStore(),
        credentialImporter: any CredentialImporting = SystemCredentialImporter(),
        mapper: CredentialExchangeMapper = CredentialExchangeMapper(),
        merger: SnapshotMerger = SnapshotMerger(),
        resolver: CredentialResolver = CredentialResolver(),
        authorizer: any CredentialReleaseAuthorizing = LocalCredentialReleaseAuthorizer(),
        bridge: AgentBridgeDirectory = AgentBridgeDirectory(),
        accessControl: CredentialAccessController = CredentialAccessController(),
        includeExampleCredential: Bool = false,
        approvalWindowPresenter: ApprovalWindowPresenter? = nil
    ) {
        self.store = store
        self.credentialImporter = credentialImporter
        self.mapper = mapper
        self.merger = merger
        self.resolver = resolver
        self.authorizer = authorizer
        self.bridge = bridge
        self.accessControl = accessControl
        self.includeExampleCredential = includeExampleCredential
        self.pasteboard = ExpiringPasteboard()
        self.approvalWindowPresenter =
            approvalWindowPresenter
            ?? {
                ApprovalWindowPresentation(
                    window: ApprovalWindowPositioner.agentKeyringWindow(),
                    closeWhenFinished: false
                )
            }
    }

    public func loadStatus() async {
        defer { isLoading = false }
        do {
            let generation = generationIncludingExample(try await store.loadCurrent())
            status = generation?.safeStatus
            if let generation {
                await accessControl.refresh(from: generation)
            }
        } catch {
            notice = MirrorNotice(
                kind: .error,
                text: "The encrypted mirror could not be opened. Apple Passwords was not changed."
            )
        }
    }

    public func receive(_ activity: NSUserActivity) {
        credentialExchangeLogger.info(
            "Received user activity type: \(activity.activityType, privacy: .public)"
        )

        guard activity.activityType == ASCredentialExchangeActivity else {
            credentialExchangeLogger.notice("Ignored unrelated user activity")
            return
        }

        guard let token = importToken(from: activity) else {
            credentialExchangeLogger.error("Credential exchange activity had no import token")
            notice = MirrorNotice(
                kind: .error,
                text:
                    "Apple Passwords opened Agent Keyring without an import token. Try the export again."
            )
            return
        }

        guard handledTokens.insert(token).inserted else {
            credentialExchangeLogger.notice("Ignored a duplicate import token")
            return
        }

        credentialExchangeLogger.info("Accepted credential import token")
        Task { await importCredentials(token: token) }
    }

    public func requestProviderEnablement() {
        providerState = .requesting
        notice = nil
        ASSettingsHelper.requestToTurnOnCredentialProviderExtension { [weak self] enabled in
            Task { @MainActor in
                self?.providerState = enabled ? .enabled : .denied
                self?.notice =
                    enabled
                    ? MirrorNotice(
                        kind: .information,
                        text: "Agent Keyring is ready as an export destination."
                    )
                    : MirrorNotice(
                        kind: .warning,
                        text:
                            "Apple did not enable the extension. This build needs an eligible Apple Developer Program profile."
                    )
            }
        }
    }

    public func openPasswords() {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Passwords")
        else {
            notice = MirrorNotice(kind: .error, text: "Apple Passwords could not be opened.")
            return
        }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.notice = MirrorNotice(
                    kind: .error,
                    text: "Apple Passwords could not be opened."
                )
            }
        }
    }

    public func receiveAgentRequest(_ url: URL) {
        guard url.scheme == "agentkeyring",
            url.host == "agent",
            let idText = url.pathComponents.last,
            let id = UUID(uuidString: idText)
        else {
            agentBridgeLogger.error("Ignored malformed agent request URL")
            return
        }

        guard handledAgentRequests.insert(id).inserted else {
            agentBridgeLogger.notice("Ignored duplicate agent request")
            return
        }

        agentBridgeLogger.info("Received agent request")
        Task { await handleAgentRequest(id: id) }
    }

    private func importToken(from activity: NSUserActivity) -> UUID? {
        if let token = activity.userInfo?[ASCredentialImportToken] as? UUID {
            return token
        }
        if let token = activity.userInfo?[ASCredentialImportToken] as? NSUUID {
            return token as UUID
        }
        return nil
    }

    func importCredentials(token: UUID) async {
        isImporting = true
        notice = nil
        defer { isImporting = false }

        credentialExchangeLogger.info("Credential import started")

        let hadExistingMirror = status != nil
        let exportedData: ASExportedCredentialData
        do {
            exportedData = try await credentialImporter.importCredentials(token: token)
            credentialExchangeLogger.info("Apple credential import completed")
        } catch {
            let failure = CredentialImportFailure(
                error: error,
                hadExistingMirror: hadExistingMirror
            )
            credentialExchangeLogger.error(
                "Credential transfer failed [\(failure.diagnostic, privacy: .public)]"
            )
            notice = MirrorNotice(kind: .error, text: failure.message)
            return
        }

        do {
            let previousGeneration = try await store.loadCurrent()
            let importBatch = mapper.map(exportedData, scope: .full)
            credentialExchangeLogger.info(
                "Mapped \(importBatch.items.count, privacy: .public) items; skipped \(importBatch.skippedCredentialCount, privacy: .public) unsupported credentials"
            )
            let generation = try merger.merge(
                previous: previousGeneration,
                importBatch: importBatch
            )
            try await store.save(generation)
            let visibleGeneration = generationIncludingExample(generation) ?? generation
            await accessControl.refresh(from: visibleGeneration)
            credentialExchangeLogger.info(
                "Saved encrypted mirror with \(generation.items.count, privacy: .public) items"
            )
            status = visibleGeneration.safeStatus
            notice = MirrorNotice(
                kind: .information,
                text:
                    "Import complete. Agent Keyring’s encrypted copy now matches this Passwords export."
            )
        } catch {
            let nsError = error as NSError
            credentialExchangeLogger.error(
                "Mirror update failed [\(nsError.domain, privacy: .public)/\(nsError.code, privacy: .public)]"
            )
            notice = MirrorNotice(
                kind: .error,
                text: hadExistingMirror
                    ? "Passwords transferred the credentials, but the encrypted mirror could not be updated. Your existing mirror was not changed."
                    : "Passwords transferred the credentials, but Agent Keyring could not create the encrypted mirror."
            )
        }
    }

    private func handleAgentRequest(id: UUID) async {
        defer { bridge.removeRequest(id: id) }
        let response: AgentBridgeResponse
        var caller: AgentBridgeRequest?
        do {
            let request = try bridge.readRequest(id: id)
            caller = request
            guard request.version == 1, request.id == id else {
                throw AgentBridgeFailure(.invalidRequest, "The agent request is invalid.")
            }
            let age = Date().timeIntervalSince(request.createdAt)
            guard age >= -5, age <= 120 else {
                throw AgentBridgeFailure(
                    .requestExpired, "The agent request expired before it was handled.")
            }
            guard let generation = generationIncludingExample(try await store.loadCurrent()) else {
                throw AgentBridgeFailure(.mirrorUnavailable, "No encrypted mirror is available yet.")
            }
            response = try await process(request: request, generation: generation)
        } catch let failure as AgentBridgeFailure {
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: failure.code,
                message: failure.message
            )
        } catch let error as CredentialResolverError {
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: bridgeCode(for: error),
                message: error.localizedDescription
            )
        } catch let error as CredentialReleaseAuthorizationError {
            let code: AgentBridgeErrorCode =
                switch error {
                case .unavailable, .busy, .systemFailure: .authorizationUnavailable
                case .denied: .authorizationDenied
                case .expired: .requestExpired
                }
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: code,
                message: error.localizedDescription
            )
        } catch {
            agentBridgeLogger.error(
                "Agent request failed: \(String(describing: error), privacy: .private)"
            )
            response = AgentBridgeResponse(
                id: id,
                ok: false,
                error: .internalError,
                message: "Agent Keyring could not handle the agent request."
            )
        }

        if let caller,
            (!bridge.requestMatches(caller) || !bridge.callerIsAlive(pid: caller.callerPID))
        {
            agentBridgeLogger.notice("Skipped a response because the requesting process ended")
            return
        }

        do {
            try bridge.write(response)
            agentBridgeLogger.info(
                "Completed agent request; success: \(response.ok, privacy: .public)")
        } catch {
            agentBridgeLogger.error("Could not write the safe agent response")
        }
    }

    private func process(
        request: AgentBridgeRequest,
        generation: MirrorGeneration
    ) async throws -> AgentBridgeResponse {
        await accessControl.refresh(from: generation)
        let mirror = AgentMirrorSummary(
            importedAt: generation.createdAt,
            ageSeconds: max(0, Int(Date().timeIntervalSince(generation.createdAt))),
            credentialCount: generation.items.count
        )

        switch request.action {
        case .status:
            return AgentBridgeResponse(id: request.id, ok: true, mirror: mirror)
        case .resolve:
            guard let targetURL = request.targetURL else {
                throw AgentBridgeFailure(.invalidRequest, "The resolve request needs a target URL.")
            }
            let candidates = try resolver.candidates(
                in: generation,
                targetURL: targetURL,
                usernameHint: request.usernameHint
            )
            guard !candidates.isEmpty else {
                return AgentBridgeResponse(
                    id: request.id,
                    ok: false,
                    error: .notFound,
                    message: CredentialResolverError.notFound.localizedDescription,
                    mirror: mirror,
                    candidates: []
                )
            }
            return AgentBridgeResponse(
                id: request.id,
                ok: true,
                mirror: mirror,
                candidates: candidates
            )
        case .copy, .acquire:
            return try await AgentCredentialReleaseProcessor(
                bridge: bridge, accessControl: accessControl, resolver: resolver
            ).release(
                request: request,
                generation: generation,
                authorize: { approval in
                    try await self.authorizeCredentialRelease(approval, agentRequest: request)
                },
                copyNative: { secret, expiration in
                    self.pasteboard.copy(secret, expiresAfter: expiration)
                }
            )
        }
    }

    private func generationIncludingExample(_ generation: MirrorGeneration?) -> MirrorGeneration? {
        guard includeExampleCredential else { return generation }

        let item = MirrorItem(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1)),
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: "com.agentkeyring.example",
                accountID: Data("example@example.com".utf8),
                itemID: Data("example.com".utf8)
            ),
            title: "example.com",
            origins: ["https://example.com"],
            credentials: [
                .password(userName: "example@example.com", password: "example-password")
            ]
        )

        guard let generation else {
            return MirrorGeneration(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0)),
                previousGenerationID: nil,
                createdAt: Date(),
                sourceExportedAt: Date(),
                scope: .full,
                exporterIdentifier: "com.agentkeyring.example",
                exporterDisplayName: "Agent Keyring",
                items: [item],
                delta: MirrorDelta(addedItemIDs: [item.id]),
                skippedCredentialCount: 0
            )
        }

        guard !generation.items.contains(where: { $0.id == item.id }) else {
            return generation
        }
        return MirrorGeneration(
            id: generation.id,
            previousGenerationID: generation.previousGenerationID,
            createdAt: generation.createdAt,
            sourceExportedAt: generation.sourceExportedAt,
            scope: generation.scope,
            exporterIdentifier: generation.exporterIdentifier,
            exporterDisplayName: generation.exporterDisplayName,
            items: generation.items + [item],
            delta: generation.delta,
            skippedCredentialCount: generation.skippedCredentialCount,
            skippedCredentialSummary: generation.skippedCredentialSummary
        )
    }

    private func authorizeCredentialRelease(
        _ approval: CredentialReleaseAuthorizationRequest,
        agentRequest: AgentBridgeRequest
    ) async throws {
        guard pendingCredentialRelease == nil else {
            throw CredentialReleaseAuthorizationError.busy
        }

        let presentation = await approvalWindowPresenter()
        guard let window = presentation.window else {
            throw AgentBridgeFailure(
                .authorizationUnavailable, "Agent Keyring could not show its approval window."
            )
        }
        let originalOrigin = window.frame.origin
        let originalLevel = window.level
        window.level = .floating
        pendingCredentialRelease = approval
        NSApplication.shared.activate(ignoringOtherApps: true)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(250))
        ApprovalWindowPositioner.centre(window)
        let existingSystemPromptIDs =
            ApprovalWindowPositioner
            .visibleSystemPromptWindowIDs()
        let positioningTask = Task { @MainActor in
            await ApprovalWindowPositioner.alignWhenSystemPromptAppears(
                window,
                excluding: existingSystemPromptIDs
            )
        }
        let leaseMonitorTask = Task { @MainActor [weak self] in
            if let self {
                await self.monitorAgentRequestLease(agentRequest)
            }
        }

        do {
            try await authorizer.authorize(approval)
        } catch {
            await stopApprovalTasks(positioningTask, leaseMonitorTask)
            let requestIsLive = agentRequestIsLive(agentRequest)
            restoreStatusWindow(
                presentation,
                origin: originalOrigin,
                level: originalLevel
            )
            if !requestIsLive {
                throw AgentBridgeFailure(
                    .requestExpired,
                    "The credential request ended before approval completed."
                )
            }
            throw error
        }
        await stopApprovalTasks(positioningTask, leaseMonitorTask)
        let requestIsLive = agentRequestIsLive(agentRequest)
        restoreStatusWindow(
            presentation,
            origin: originalOrigin,
            level: originalLevel
        )
        guard requestIsLive else {
            throw AgentBridgeFailure(
                .requestExpired,
                "The credential request ended before approval completed."
            )
        }
    }

    private func restoreStatusWindow(
        _ presentation: ApprovalWindowPresentation,
        origin: CGPoint?,
        level: NSWindow.Level?
    ) {
        pendingCredentialRelease = nil
        if let window = presentation.window {
            if let level { window.level = level }
            if let origin { window.setFrameOrigin(origin) }
            if presentation.miniaturizeWhenFinished {
                window.miniaturize(nil)
            } else if presentation.closeWhenFinished {
                window.close()
            }
        }
    }

    private func stopApprovalTasks(
        _ positioningTask: Task<Void, Never>,
        _ leaseMonitorTask: Task<Void, Never>
    ) async {
        positioningTask.cancel()
        leaseMonitorTask.cancel()
        await positioningTask.value
        await leaseMonitorTask.value
    }

    private func monitorAgentRequestLease(_ request: AgentBridgeRequest) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if !agentRequestIsLive(request) {
                authorizer.cancelCurrentAuthorization()
                return
            }
        }
    }

    private func agentRequestIsLive(_ request: AgentBridgeRequest) -> Bool {
        request.createdAt.addingTimeInterval(120) > Date()
            && bridge.requestMatches(request)
            && bridge.callerIsAlive(pid: request.callerPID)
    }

    private func bridgeCode(for error: CredentialResolverError) -> AgentBridgeErrorCode {
        switch error {
        case .invalidURL: .invalidURL
        case .insecureOrigin: .insecureOrigin
        case .notFound: .notFound
        case .ambiguous: .ambiguous
        case .fieldUnavailable: .fieldUnavailable
        case .invalidTOTP: .invalidTOTP
        }
    }
}

@MainActor
private final class ExpiringPasteboard {
    func copy(_ value: String, expiresAfter interval: TimeInterval) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        let changeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
        }
    }
}
