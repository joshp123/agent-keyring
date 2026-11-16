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
    /// Sends the imported list to the Mac mini, signed with a context Josh has
    /// already approved in the panel.
    public func sendImportedLogins(context: LAContext) async throws {
        try await relayApprover.publishCurrentRules(context: context,
            reason: "let agents on your other machines use the logins you just imported")
        importedLoginsAwaitApproval = false
    }

    /// "Not now": the rules window keeps offering to send the list.
    public func declineSendingImportedLogins() {
        importedLoginsAwaitApproval = false
        relayApprover.noteRulesChanged()
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

        credentialExchangeLogger.info("Import token present")
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

    public func openPasswordsExport() {
        notice = MirrorNotice(kind: .information, text: MirrorSyncReminders.exportInstruction)
        openPasswords()
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

        let generation: MirrorGeneration
        do {
            let previousGeneration = try await store.loadCurrent()
            let importBatch = mapper.map(exportedData, scope: .unknown)
            credentialExchangeLogger.info(
                "Mapped \(importBatch.items.count, privacy: .public) items; skipped \(importBatch.skippedCredentialCount, privacy: .public) unsupported credentials"
            )
            generation = try merger.merge(previous: previousGeneration, importBatch: importBatch)
            credentialExchangeLogger.info("Merge completed with \(generation.items.count, privacy: .public) items")
            try await store.save(generation)
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
            return
        }

        credentialExchangeLogger.info("Saved encrypted mirror with \(generation.items.count, privacy: .public) items")
        staleLogins.clear()
        let visibleGeneration = generationIncludingExample(generation) ?? generation
        // The example login is for exercising requests, not an imported login.
        status = generation.safeStatus
        leaseLogins = visibleGeneration.metadata.candidates
        await accessControl.refresh(from: visibleGeneration)
        do {
            try await refreshLeasePolicy()
            try relayApprover.load()
            if relayApprover.state.keySet != nil {
                let vault = RelayApproverVault(generation: visibleGeneration,
                    policies: Dictionary(uniqueKeysWithValues: leaseLogins.map { ($0.id, accessControl.policy(for: $0.id)) }))
                if try relayApprover.requiresPublicationConfirmation(vault) {
                    // Josh approves sending the list in a panel beside his window.
                    importedLoginsAwaitApproval = true
                    notice = MirrorNotice(kind: .information,
                        text: "Import complete. Agents on your other machines can use the new list once you allow it.")
                    return
                } else {
                    relayApprover.noteRulesChanged()
                }
            }
            notice = MirrorNotice(kind: .information,
                text: "Import complete. Exported logins have been updated.")
        } catch {
            let error = error as NSError
            credentialExchangeLogger.error(
                "Mirror saved; access rules could not be applied [\(error.domain, privacy: .public)/\(error.code, privacy: .public)]"
            )
            let nextStep = leaseStore.needsHistoryReset
                ? "Reset task history in Agent Keyring to restore agent access."
                : "Confirm your access rules in Agent Keyring before agents use them."
            notice = MirrorNotice(kind: .warning,
                text: "Import complete. Your logins were saved. \(nextStep)")
        }
    }
}
