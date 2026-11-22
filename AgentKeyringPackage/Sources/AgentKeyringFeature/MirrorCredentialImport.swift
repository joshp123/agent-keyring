import AppKit
import AuthenticationServices
import Foundation
import LocalAuthentication
import OSLog

private let credentialExchangeLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "Import"
)

@available(macOS 26.0, *)
extension MirrorAppModel {
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
            problem = MessageCopy.exportSentNothing
            return
        }

        guard handledTokens.insert(token).inserted else {
            credentialExchangeLogger.notice("Ignored a duplicate import token")
            return
        }

        credentialExchangeLogger.info("Import token present")
        Task { await importCredentials(token: token) }
    }

    /// "Open Passwords". After five minutes with nothing arrived, first run says so;
    /// passwords that arrived first have already moved it on, so the late timer changes nothing.
    public func openPasswordsExport() {
        if passwordsCopy == nil { copyGuideStep = 1 }
        problem = nil
        passwordsCopy = .waiting
        exportTimeout?.cancel()
        exportTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, self.passwordsCopy == .waiting else { return }
            self.passwordsCopy = .noneArrived
        }
        openPasswords()
    }

    /// Cancel on the main window's copy, or the copy ending: the list comes back.
    public func closePasswordsCopy() {
        exportTimeout?.cancel()
        passwordsCopy = nil
    }

    /// The earlier Agent Keyring (0.2.5, identifier without ".Mac") is on this
    /// Mac, so Passwords lists "AgentKeyring" beside "Agent Keyring".
    public static var earlierVersionInstalled: Bool {
        guard let identifier = Bundle.main.bundleIdentifier, identifier.hasSuffix(".Mac") else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(identifier.dropLast(4))) != nil
    }

    /// "Agent Keyring isn't in the list?": the sheet that sends him to AutoFill settings.
    public func explainAllowExport() {
        passwordsCopy = .allowExport
    }

    /// Open AutoFill Settings: System Settings opens at AutoFill, where he turns on Agent Keyring.
    public func openAutoFillSettings() {
        Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() }
    }

    /// The app came to the front: if he turned Agent Keyring on in AutoFill, the sheet closes and he starts the export again.
    public func recheckAutoFill() {
        guard passwordsCopy == .allowExport else { return }
        Task {
            guard await ASCredentialIdentityStore.shared.state().isEnabled, passwordsCopy == .allowExport else { return }
            passwordsCopy = .steps
        }
    }

    /// Cancel on the AutoFill sheet: back to the guide.
    public func closeAllowExport() {
        guard passwordsCopy == .allowExport else { return }
        passwordsCopy = .steps
    }

    /// The test password only, for now: a copy of nothing, which brings the
    /// test password if no copy has yet. Nothing to send if one has.
    public func useTestPassword() async {
        if (try? await store.loadCurrent())?.items.contains(where: \.isTestPassword) != true {
            guard await importBatch(MirrorImportBatch(scope: .unknown, exportedAt: .now, exporterIdentifier: MirrorItem.testPasswordSource,
                exporterDisplayName: "Test password", items: [], skippedCredentialCount: 0), hadExistingMirror: status != nil)
            else { return }
        }
        closePasswordsCopy()
        send(.useTestPasswordOnly)
    }

    public func openPasswords() {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Passwords")
        else {
            problem = MessageCopy.passwordsWontOpen
            return
        }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.problem = MessageCopy.passwordsWontOpen
            }
        }
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
        exportTimeout?.cancel()
        passwordsCopy = .copying
        // A failed copy goes back to the steps, with the error under them.
        defer { if passwordsCopy == .copying { passwordsCopy = .steps } }
        problem = nil

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
            problem = failure.message
            DiagnosticLog.record("copy", "failed", ["reason": failure.diagnostic])
            return
        }

        let copied = mapper.map(exportedData, scope: .full)
        if await importBatch(copied, hadExistingMirror: hadExistingMirror) {
            closePasswordsCopy()
            askToSendChanges()
            // He is in Passwords: the Dock icon bounces once; the window is never pushed in front.
            if !NSApplication.shared.isActive { NSApplication.shared.requestUserAttention(.informationalRequest) }
        }
    }

    /// True once the import is sealed and saved.
    @discardableResult
    func importBatch(_ copied: MirrorImportBatch, hadExistingMirror: Bool) async -> Bool {
        let generation: MirrorGeneration
        do {
            // Every copy keeps one test password; the first one brings it.
            let previous = try await store.loadCurrent()
            let importBatch = previous?.items.contains(where: \.isTestPassword) == true ? copied
                : MirrorImportBatch(scope: copied.scope, exportedAt: copied.exportedAt, exporterIdentifier: copied.exporterIdentifier,
                    exporterDisplayName: copied.exporterDisplayName, items: copied.items + [MirrorItem.testPassword],
                    skippedCredentialCount: copied.skippedCredentialCount, skippedCredentialSummary: copied.skippedCredentialSummary)
            credentialExchangeLogger.info(
                "Mapped \(importBatch.items.count, privacy: .public) items; skipped \(importBatch.skippedCredentialCount, privacy: .public) unsupported credentials"
            )
            generation = try merger.merge(previous: previous, importBatch: importBatch,
                keep: Set((previous?.items ?? []).map(\.id).filter { accessControl.policy(for: $0) != .ask }))
            // Seal only what arrived: a login missing from this export keeps
            // its earlier copies, and the saved list holds no secrets to seal.
            // The other devices' earlier copies stay too, until he sends the
            // changes: they are served while the signed catalogue still names
            // their versions, and pruned when it is signed again (MacDevice.publish).
            let arrived = Set(importBatch.items.map(\.sourceIdentity))
            let fresh = generation.items.filter { arrived.contains($0.sourceIdentity) }
            let kept = Set(generation.items.filter { !arrived.contains($0.sourceIdentity) }.map(\.id.uuidString))
            let keys = try macKeys()
            let ownMachineID = keys.machineID // This Mac's local Automatic copies update at import; keep its chip-key copy of the last signed version until publication.
            let saveGeneration: @MainActor () async throws -> Void = { [self] in
                let signed = Dictionary((self.device?.catalogue?.logins ?? []).map { ($0.loginID, $0.version) }, uniquingKeysWith: { first, _ in first })
                let version = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
                let incoming = try fresh.flatMap { item in
                    let policy = self.accessControl.policy(for: item.id)
                    return try self.sealCopies(of: item.secret, version: version, automatic: policy == .allowAutomatically, blocked: policy == .block)
                }
                try await self.store.save(generation) { existing in
                    let preserved = existing.filter { copy in
                        kept.contains(copy.loginID) || (copy.openerID != ownMachineID && signed[copy.loginID] == copy.version)
                    }
                    return preserved + incoming
                }
                self.status = generation.safeStatus
                self.leaseLogins = generation.metadata.candidates
            }
            if let device {
                try await device.withSerializedCatalogue(saveGeneration)
            } else {
                try await saveGeneration()
            }
        } catch {
            credentialExchangeLogger.error("Sealing the import failed: \(String(describing: error), privacy: .public)")
            problem = MessageCopy.notLockedAway(hadEarlierCopy: hadExistingMirror)
            return false
        }

        credentialExchangeLogger.info("Saved encrypted mirror with \(generation.items.count, privacy: .public) items")
        await accessControl.refresh(from: generation)
        await noteMissingAutomaticCopies()
        problem = nil
        return true
    }
}
