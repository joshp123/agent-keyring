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
    /// Sends the new catalogue and the copies sealed to the other devices,
    /// signed with a context Josh has just approved in the panel.
    public func sendImportedLogins(context: LAContext) async throws {
        try await device?.publish(context: context)
        importedLoginsAwaitApproval = false
    }

    /// "Not now": the other devices keep the previous list until the next change.
    public func declineSendingImportedLogins() {
        importedLoginsAwaitApproval = false
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

    /// "Agent Keyring isn't in the list?"
    public func explainAllowExport() {
        passwordsCopy = .allowExport(asking: false)
    }

    /// Continue on "Allow export from Passwords": macOS asks "Turn on AutoFill
    /// from “Agent Keyring”?". Turn On goes back to the steps. After Not Now the
    /// screen stays, and Continue comes back after macOS's 10 seconds.
    public func askToAllowExport() {
        guard passwordsCopy == .allowExport(asking: false) else { return }
        passwordsCopy = .allowExport(asking: true)
        let asked = ContinuousClock.now
        ASSettingsHelper.requestToTurnOnCredentialProviderExtension { [weak self] enabled in
            Task { @MainActor in
                guard let self, self.passwordsCopy == .allowExport(asking: true) else { return }
                if enabled { self.passwordsCopy = .steps; return }
                try? await Task.sleep(until: asked + .seconds(10))
                if self.passwordsCopy == .allowExport(asking: true) { self.passwordsCopy = .allowExport(asking: false) }
            }
        }
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
        send(.useSample)
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
            send(.imported(count: copied.items.count))
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
            let arrived = Set(importBatch.items.map(\.sourceIdentity))
            let fresh = generation.items.filter { arrived.contains($0.sourceIdentity) }
            let kept = Set(generation.items.filter { !arrived.contains($0.sourceIdentity) }.map(\.id.uuidString))
            var sealed = try await store.sealed().filter { kept.contains($0.loginID) }
            let version = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            for item in fresh {
                let policy = accessControl.policy(for: item.id)
                sealed += try sealCopies(of: item.secret, version: version, automatic: policy == .allowAutomatically, blocked: policy == .block)
            }
            try await store.save(generation, sealed: sealed)
        } catch {
            credentialExchangeLogger.error("Sealing the import failed: \(String(describing: error), privacy: .public)")
            problem = MessageCopy.notLockedAway(hadEarlierCopy: hadExistingMirror)
            return false
        }

        credentialExchangeLogger.info("Saved encrypted mirror with \(generation.items.count, privacy: .public) items")
        status = generation.safeStatus
        leaseLogins = generation.metadata.candidates
        await accessControl.refresh(from: generation)
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        if device?.hasMembers == true {
            // Josh approves sending the list in a panel beside his window.
            importedLoginsAwaitApproval = true
        }
        problem = nil
        return true
    }
}
