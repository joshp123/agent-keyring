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
    private let merger: SnapshotMerger
    private let resolver: CredentialResolver
    private let authorizer: any CredentialReleaseAuthorizing
    private let bridge: AgentBridgeDirectory
    private let pasteboard: ExpiringPasteboard
    private let approvalWindowPresenter: ApprovalWindowPresenter
    private var handledTokens = Set<UUID>()
    private var handledAgentRequests = Set<UUID>()

    public init(
        store: EncryptedSnapshotStore = EncryptedSnapshotStore(),
        mapper: CredentialExchangeMapper = CredentialExchangeMapper(),
        merger: SnapshotMerger = SnapshotMerger(),
        resolver: CredentialResolver = CredentialResolver(),
        authorizer: any CredentialReleaseAuthorizing = LocalCredentialReleaseAuthorizer(),
        bridge: AgentBridgeDirectory = AgentBridgeDirectory(),
        accessControl: CredentialAccessController = CredentialAccessController(),
        approvalWindowPresenter: ApprovalWindowPresenter? = nil
    ) {
        self.store = store
        self.mapper = mapper
        self.merger = merger
        self.resolver = resolver
        self.authorizer = authorizer
        self.bridge = bridge
        self.accessControl = accessControl
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
            let generation = try await store.loadCurrent()
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

    private func importCredentials(token: UUID) async {
        isImporting = true
        notice = nil
        defer { isImporting = false }

        credentialExchangeLogger.info("Credential import started")

        do {
            let exportedData = try await ASCredentialImportManager()
                .importCredentials(token: token)
            credentialExchangeLogger.info("Apple credential import completed")
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
            await accessControl.refresh(from: generation)
            credentialExchangeLogger.info(
                "Saved encrypted mirror with \(generation.items.count, privacy: .public) items"
            )
            status = generation.safeStatus
            notice = MirrorNotice(
                kind: .information,
                text: "Refresh complete. The new mirror is encrypted and ready."
            )
        } catch {
            credentialExchangeLogger.error(
                "Credential import failed: \(String(describing: error), privacy: .private)"
            )
            notice = MirrorNotice(
                kind: .error,
                text: status == nil
                    ? "Import failed. In Passwords, choose Export All Items and try again."
                    : "Refresh failed. Your existing encrypted mirror was not changed."
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
            guard let generation = try await store.loadCurrent() else {
                throw AgentBridgeFailure(
                    .mirrorUnavailable, "No encrypted mirror is available yet.")
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
                case .unavailable, .busy: .authorizationUnavailable
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
        case .copy:
            guard let targetURL = request.targetURL, let field = request.field else {
                throw AgentBridgeFailure(
                    .invalidRequest, "The copy request needs a target URL and field.")
            }
            let candidates = try resolver.candidates(
                in: generation,
                targetURL: targetURL,
                usernameHint: request.usernameHint
            )
            guard !candidates.isEmpty else { throw CredentialResolverError.notFound }
            if request.candidateID == nil, candidates.count > 1 {
                return AgentBridgeResponse(
                    id: request.id,
                    ok: false,
                    error: .ambiguous,
                    message: CredentialResolverError.ambiguous.localizedDescription,
                    mirror: mirror,
                    candidates: candidates
                )
            }

            let selected: CredentialCandidate
            if let candidateID = request.candidateID {
                guard let candidate = candidates.first(where: { $0.id == candidateID }) else {
                    throw CredentialResolverError.notFound
                }
                selected = candidate
            } else {
                guard let candidate = candidates.first else {
                    throw CredentialResolverError.notFound
                }
                selected = candidate
            }
            guard selected.availableFields.contains(field) else {
                throw CredentialResolverError.fieldUnavailable
            }

            let releaseDecision = accessControl.releaseDecision(
                for: selected.id,
                field: field
            )
            if releaseDecision == .block {
                throw AgentBridgeFailure(
                    .policyDenied,
                    "Agent access to this credential is blocked in Agent Keyring."
                )
            }

            if releaseDecision == .requestAuthorization {
                let approval = CredentialReleaseAuthorizationRequest(
                    destination: approvalDestination(for: targetURL),
                    account: selected.username ?? selected.title,
                    field: field,
                    credentialTitle: selected.title,
                    expirationSeconds: min(120, max(5, request.expirationSeconds)),
                    authorizationDeadline: request.createdAt.addingTimeInterval(120)
                )
                try await authorizeCredentialRelease(
                    approval,
                    agentRequest: request
                )
            }

            try ensureAgentRequestIsLive(request)
            let secret = try resolver.secret(
                in: generation,
                targetURL: targetURL,
                usernameHint: request.usernameHint,
                candidateID: request.candidateID,
                field: field
            )
            let expiration = min(120, max(5, request.expirationSeconds))
            pasteboard.copy(secret, expiresAfter: TimeInterval(expiration))
            return AgentBridgeResponse(
                id: request.id,
                ok: true,
                mirror: mirror,
                copiedField: field,
                clipboardExpiresAt: Date().addingTimeInterval(TimeInterval(expiration))
            )
        }
    }

    private func approvalDestination(for targetURL: String) -> String {
        guard let components = URLComponents(string: targetURL),
            let host = components.host
        else { return "the requested site" }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
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
            throw CredentialReleaseAuthorizationError.unavailable
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

    private func ensureAgentRequestIsLive(_ request: AgentBridgeRequest) throws {
        guard agentRequestIsLive(request) else {
            throw AgentBridgeFailure(
                .requestExpired,
                "The credential request ended before the secret was released."
            )
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

private struct AgentBridgeFailure: Error {
    let code: AgentBridgeErrorCode
    let message: String

    init(_ code: AgentBridgeErrorCode, _ message: String) {
        self.code = code
        self.message = message
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
