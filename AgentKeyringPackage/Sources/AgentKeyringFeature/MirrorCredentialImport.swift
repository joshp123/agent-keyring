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
            notice = MirrorNotice(
                kind: .error,
                text:
                    "Passwords opened Agent Keyring without sending your passwords. Try the export again."
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

    /// "Open Passwords". After five minutes with nothing arrived, first run says so;
    /// passwords that arrived first have already moved it on, so the late timer changes nothing.
    public func openPasswordsExport() {
        send(.openPasswords)
        exportTimeout?.cancel()
        exportTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.send(.exportTimedOut)
        }
        openPasswords()
    }

    /// "Use a Sample Password": one ordinary Ask password, which his first copy from Passwords replaces.
    public func useSamplePassword() async {
        guard await importBatch(MirrorImportBatch(scope: .full, exportedAt: .now, exporterIdentifier: MirrorItem.sampleExporter,
            exporterDisplayName: "Sample", items: [MirrorItem.sample], skippedCredentialCount: 0), hadExistingMirror: status != nil)
        else { return }
        send(.useSample)
    }

    public func openPasswords() {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Passwords")
        else {
            notice = MirrorNotice(kind: .error, text: "Passwords could not be opened.")
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
                    text: "Passwords could not be opened."
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
        send(.importStarted)
        exportTimeout?.cancel()
        notice = nil

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
            send(.importFailed)
            return
        }

        if await importBatch(mapper.map(exportedData, scope: .unknown), hadExistingMirror: hadExistingMirror), let status {
            send(.imported(count: status.credentialItemCount))
        } else {
            send(.importFailed)
        }
    }

    /// True once the import is sealed and saved.
    @discardableResult
    func importBatch(_ importBatch: MirrorImportBatch, hadExistingMirror: Bool) async -> Bool {
        let generation: MirrorGeneration
        do {
            credentialExchangeLogger.info(
                "Mapped \(importBatch.items.count, privacy: .public) items; skipped \(importBatch.skippedCredentialCount, privacy: .public) unsupported credentials"
            )
            generation = try merger.merge(previous: try await store.loadCurrent(), importBatch: importBatch)
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
            notice = MirrorNotice(
                kind: .error,
                text: hadExistingMirror
                    ? "Passwords sent your passwords, but Agent Keyring could not lock them away. Your earlier copy was not changed."
                    : "Passwords sent your passwords, but Agent Keyring could not lock them away."
            )
            return false
        }

        credentialExchangeLogger.info("Saved encrypted mirror with \(generation.items.count, privacy: .public) items")
        status = generation.safeStatus
        leaseLogins = generation.metadata.candidates
        await accessControl.refresh(from: generation)
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        if device?.isJoined == true {
            // Josh approves sending the list in a panel beside his window.
            importedLoginsAwaitApproval = true
            notice = MirrorNotice(kind: .information,
                text: "Your passwords are copied. Your iPhone and other computers get them once you allow it.")
        } else {
            notice = MirrorNotice(kind: .information, text: "Your passwords are copied.")
        }
        return true
    }
}
