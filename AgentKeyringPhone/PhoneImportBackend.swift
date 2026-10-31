import AgentKeyringApprovalUI
import AgentKeyringCredentialImport
import AuthenticationServices
import Foundation
import OSLog

private let phoneImportLogger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Import")

@MainActor
final class PhoneImportBackend: PhoneKeyringBackend {
    private let importer: any CredentialImporting
    private let destination: any PhoneCredentialImportDestination
    private var subscribers: [UUID: AsyncStream<PhoneKeyringSnapshot>.Continuation] = [:]
    private var handledTokens = Set<UUID>()
    private var pendingTokens: [UUID] = []
    private var importTask: Task<Void, Never>?
    private var openingPasswords = false
    private var lastProviderEnablementRequest: Date?

    private(set) var snapshot = PhoneKeyringSnapshot(
        requests: [], passwords: .notImported, connection: .notPaired,
        settings: PhoneSettings(askPhoneAfter: .seconds(120), notificationsAllowed: false, keyFingerprint: "Not set up")
    ) {
        didSet { for continuation in subscribers.values { continuation.yield(snapshot) } }
    }

    init(
        importer: any CredentialImporting = SystemCredentialImporter(),
        destination: any PhoneCredentialImportDestination = EncryptedPhoneImportDestination()
    ) {
        self.importer = importer
        self.destination = destination
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

    // The relay and approval backend arrive in R4.3. Never manufacture an answer.
    func approve(requestID: String) async throws -> AccessRequestState { throw PhoneImportBackendFailure.approvalsUnavailable }
    func deny(requestID: String, reply: String?) async throws -> AccessRequestState { throw PhoneImportBackendFailure.approvalsUnavailable }
    func endAccess(requestID: String) async throws -> AccessRequestState { throw PhoneImportBackendFailure.approvalsUnavailable }
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState { throw PhoneImportBackendFailure.approvalsUnavailable }
    func setAskPhoneAfter(_ delay: Duration) async throws { throw PhoneImportBackendFailure.approvalsUnavailable }
    func dictation() -> AsyncStream<String> { AsyncStream { $0.finish() } }

    private func logFailure(_ error: any Error, stage: String) {
        let failure = CredentialImportFailure(error: error, hadExistingMirror: false)
        phoneImportLogger.error("\(stage, privacy: .public) failed [\(failure.diagnostic, privacy: .public)]")
    }
}

private enum PhoneImportBackendFailure: Error { case approvalsUnavailable }
