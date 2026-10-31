import AgentKeyringApprovalUI
import AgentKeyringCredentialImport
import AgentKeyringPhoneApprover
import AgentKeyringRelaySupport
import AuthenticationServices
import Foundation
import OSLog
import UIKit
import UserNotifications

private let phoneImportLogger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Import")

@MainActor
final class PhoneImportBackend: PhoneKeyringBackend {
    private let importer: any CredentialImporting
    private let destination: any PhoneCredentialImportDestination
    private let approver: PhoneRelayApprover
    private var approverUpdates: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<PhoneKeyringSnapshot>.Continuation] = [:]
    private var handledTokens = Set<UUID>()
    private var pendingTokens: [UUID] = []
    private var importTask: Task<Void, Never>?
    private var openingPasswords = false
    private var notificationTask: Task<Void, Never>?
    private var pushToken: Data?
    private var registeredPushToken: Data?
    private var lastProviderEnablementRequest: Date?

    private(set) var snapshot = PhoneKeyringSnapshot(
        requests: [], passwords: .notImported, connection: .notPaired,
        settings: PhoneSettings(askPhoneAfter: nil, notifications: .notSetUp, keyFingerprint: "Not set up")
    ) {
        didSet { for continuation in subscribers.values { continuation.yield(snapshot) } }
    }

    init(
        importer: any CredentialImporting = SystemCredentialImporter(),
        destination: EncryptedPhoneImportDestination = EncryptedPhoneImportDestination()
    ) {
        self.importer = importer
        self.destination = destination
        approver = PhoneRelayApprover(directory: URL.applicationSupportDirectory.appending(path: "PhoneApprover", directoryHint: .isDirectory),
                                      keys: destination.keys,
                                      identity: { try RelayTLSIdentity.loadOrCreate(service: "com.joshpalmer.AgentKeyring.Phone.relay-tls.phone-v2") })
        do {
            if let status = try destination.status() {
                snapshot.passwords = .imported(count: status.loginCount, at: status.importedAt)
            }
        } catch {
            logFailure(error, stage: "Read phone vault index")
            snapshot.passwords = .importFailed("The saved phone vault couldn't be read. Unlock this iPhone and open Agent Keyring again.")
        }
    }

    func updates() -> AsyncStream<PhoneKeyringSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func receive(_ activity: NSUserActivity) {
        guard activity.activityType == ASCredentialExchangeActivity else { return }
        phoneImportLogger.notice("Received credential exchange activity")
        guard let token = activity.userInfo?[ASCredentialImportToken] as? UUID else {
            phoneImportLogger.error("Credential exchange activity had no import token")
            snapshot.passwords = .importFailed("Passwords opened Agent Keyring without an import token. Start the export again in Passwords.")
            return
        }
        guard handledTokens.insert(token).inserted else {
            phoneImportLogger.notice("Ignored a duplicate import token")
            return
        }
        phoneImportLogger.notice("Import token present")
        pendingTokens.append(token)
        guard importTask == nil else { return }
        importTask = Task {
            while !pendingTokens.isEmpty {
                let nextToken = pendingTokens.removeFirst()
                await importCredentials(token: nextToken)
            }
            importTask = nil
        }
    }

    private func importCredentials(token: UUID) async {
        snapshot.passwords = .importing(received: 0)
        phoneImportLogger.notice("Credential import started")
        let exportedData: ASExportedCredentialData
        do {
            exportedData = try await importer.importCredentials(token: token)
            phoneImportLogger.notice("Apple credential import completed")
        } catch {
            let failure = CredentialImportFailure(error: error, hadExistingMirror: false)
            phoneImportLogger.error("Credential transfer failed [\(failure.diagnostic, privacy: .public)]")
            snapshot.passwords = .importFailed("Apple Passwords couldn't transfer the logins. Start the export again in Passwords. Existing saved logins are unchanged.")
            return
        }

        // Apple's payload does not say whether this was a full or selected
        // export. The vault must treat .unknown additively, just like the Mac.
        let batch = CredentialExchangeMapper().map(exportedData, scope: .unknown)
        let receipt = PhoneImportReceipt(batch: batch)
        phoneImportLogger.notice("Mapped \(receipt.loginCount, privacy: .public) items; passwords=\(receipt.passwordCount, privacy: .public) codes=\(receipt.codeCount, privacy: .public) skippedPasskeys=\(receipt.skippedPasskeyCount, privacy: .public) skippedMissingPassword=\(receipt.skippedMissingPasswordCount, privacy: .public) skippedOther=\(receipt.skippedOtherCount, privacy: .public)")
        snapshot.passwords = .importing(received: receipt.loginCount)
        do {
            let status = try await destination.receive(batch)
            phoneImportLogger.notice("Saved encrypted phone vault with \(status.loginCount, privacy: .public) items")
            snapshot.passwords = .imported(count: status.loginCount, at: status.importedAt)
            // Optional import never gates phone approval.
            approver.reconnect()
        } catch {
            logFailure(error, stage: "Phone vault import")
            snapshot.passwords = .importFailed("Passwords transferred \(receipt.loginCount) logins, but the phone vault could not save them. Existing saved logins are unchanged. Start the export again in Passwords.")
        }
    }

    func openPasswordsForImport() {
        guard !openingPasswords else { return }
        // ASSettingsHelper requires ten seconds between requests.
        if let lastProviderEnablementRequest, Date().timeIntervalSince(lastProviderEnablementRequest) < 10 {
            return
        }
        lastProviderEnablementRequest = Date()
        openingPasswords = true
        Task {
            defer { openingPasswords = false }
            phoneImportLogger.notice("Requested credential provider enablement")
            let enabled = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
            phoneImportLogger.notice("Credential provider enablement result: \(enabled, privacy: .public)")
            guard enabled else {
                snapshot.passwords = .importFailed("Turn on Agent Keyring in Settings → General → AutoFill & Passwords, then export from Passwords.")
                return
            }
            // iOS exposes provider settings, but no public URL for opening
            // Passwords or its export screen. Leave the existing instructions
            // visible; Josh switches to Passwords to start Apple's hand-off.
            phoneImportLogger.notice("Credential provider ready; start the export in Passwords")
        }
    }

    func start() {
        if approverUpdates == nil {
            approverUpdates = Task { [weak self] in
                guard let stream = self?.approver.changes() else { return }
                for await _ in stream { self?.refreshApproverSnapshot() }
            }
        }
        approver.reconnect()
        refreshNotifications()
    }

    func stop() {
        approver.stop()
    }

    private func refreshApproverSnapshot() {
        do {
            snapshot.requests = try approver.requests()
            snapshot.connection = approver.connection
            let wasPaired = snapshot.pairing == .paired
            snapshot.pairing = approver.pairing
            snapshot.settings.keyFingerprint = approver.keyFingerprint
            snapshot.settings.rulesUpdatedAt = approver.rulesUpdatedAt
            if !wasPaired && snapshot.pairing == .paired { refreshNotifications() }
        } catch { logFailure(error, stage: "Read approver state") }
    }

    func beginPairing(endpoint: PhoneRelayEndpoint) async throws {
        try await approver.beginPairing(endpoint: RelayEndpoint(host: endpoint.host, port: endpoint.port))
    }
    func cancelPairing() { approver.cancelPairing() }
    func approve(requestID: String) async throws -> AccessRequestState { try await approver.approve(requestID) }
    func deny(requestID: String, reply: String?) async throws -> AccessRequestState { try await approver.deny(requestID, reply: reply) }
    func endAccess(requestID: String) async throws -> AccessRequestState {
        try await approver.endAccess(requestID)
    }
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState { try await approver.clearDenial(requestID) }

    func receivedPushToken(_ token: Data) {
        pushToken = token
        refreshNotifications()
    }

    func pushRegistrationFailed(_ error: Error) {
        logFailure(error, stage: "Apple notification registration")
    }

    private func refreshNotifications() {
        guard snapshot.pairing == .paired, notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            guard let self else { return }
            defer { notificationTask = nil }
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
                catch { logFailure(error, stage: "Notification permission") }
                settings = await center.notificationSettings()
            }
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            snapshot.settings.notifications = allowed ? .notSetUp : .off
            guard allowed else { return }
            if pushToken == nil { UIApplication.shared.registerForRemoteNotifications(); return }
            guard let token = pushToken, registeredPushToken != token else { return }
            guard let environment = Bundle.main.object(forInfoDictionaryKey: "AgentKeyringAPNSEnvironment") as? String,
                  ["development", "production"].contains(environment) else {
                phoneImportLogger.error("The build has no matching notification environment")
                return
            }
            do {
                try await approver.registerPush(token: token, production: environment == "production")
                registeredPushToken = token
            } catch { logFailure(error, stage: "Relay notification registration") }
        }
    }

    private func logFailure(_ error: any Error, stage: String) {
        let failure = CredentialImportFailure(error: error, hadExistingMirror: false)
        phoneImportLogger.error("\(stage, privacy: .public) failed [\(failure.diagnostic, privacy: .public)]")
    }
}
