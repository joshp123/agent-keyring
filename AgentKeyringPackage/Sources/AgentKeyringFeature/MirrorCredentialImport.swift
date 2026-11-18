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

    /// Whether AutoFill from this app's extension is on. Each extension has its
    /// own setting: 0.2.5's being on says nothing about this one.
    func autoFillIsOn() async -> Bool {
        await withCheckedContinuation { continuation in
            ASCredentialIdentityStore.shared.getState { continuation.resume(returning: $0.isEnabled) }
        }
    }

    /// First run asks macOS as its window opens, unless loading found AutoFill
    /// from Agent Keyring already on; then the import step shows at once.
    public func askToTurnOnAutoFillIfNeeded() {
        guard status == nil, providerState == .unknown else { return }
        askToTurnOnAutoFill()
    }

    /// He may switch it on or off in System Settings while first run waits.
    public func recheckAutoFill() async {
        guard status == nil, providerState != .unknown, providerState != .requesting else { return }
        if await autoFillIsOn() { providerState = .enabled } else if providerState == .enabled { providerState = .off }
    }

    /// macOS shows "Turn on AutoFill from “Agent Keyring”?" by itself; "Ask Again" calls this too.
    public func askToTurnOnAutoFill() {
        providerState = .requesting
        canAskAgain = false
        notice = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.canAskAgain = true
        }
        ASSettingsHelper.requestToTurnOnCredentialProviderExtension { [weak self] enabled in
            Task { @MainActor in self?.providerState = enabled ? .enabled : .notNow }
        }
    }

    /// 0.2.5, whose extension Passwords also lists as "Agent Keyring". Only
    /// whether it is installed is asked of macOS; nothing of it is read.
    public var oldAppInstalled: Bool {
        guard let mine = Bundle.main.bundleIdentifier, mine.hasSuffix(".Mac") else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(mine.dropLast(4))) != nil
    }

    public func openPasswordsExport() {
        awaitingExport = true
        exportTimeout?.cancel()
        exportTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, self.awaitingExport, !self.isImporting else { return }
            self.notice = MirrorNotice(kind: .error, text: self.oldAppInstalled
                ? "No logins arrived from Passwords. They may have gone to the old Agent Keyring. In Passwords, choose File > Export All Items to App > Agent Keyring again, and pick the one with the blue keyhole."
                : "No logins arrived from Passwords. In Passwords, choose File > Export All Items to App > Agent Keyring again.")
        }
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
        defer { isImporting = false; awaitingExport = false }

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

        await importBatch(mapper.map(exportedData, scope: .unknown), hadExistingMirror: hadExistingMirror)
    }

    func importBatch(_ importBatch: MirrorImportBatch, hadExistingMirror: Bool) async {
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
            for item in fresh {
                let policy = accessControl.policy(for: item.id)
                sealed += try sealCopies(of: item.secret, automatic: policy == .allowAutomatically, phoneOnly: policy == .askOnPhone)
            }
            try await store.save(generation, sealed: sealed)
        } catch {
            credentialExchangeLogger.error("Sealing the import failed: \(String(describing: error), privacy: .public)")
            notice = MirrorNotice(
                kind: .error,
                text: hadExistingMirror
                    ? "Passwords transferred the logins, but Agent Keyring could not seal them. Your earlier import was not changed."
                    : "Passwords transferred the logins, but Agent Keyring could not seal them."
            )
            return
        }

        credentialExchangeLogger.info("Saved encrypted mirror with \(generation.items.count, privacy: .public) items")
        status = generation.safeStatus
        leaseLogins = generation.metadata.candidates
        await accessControl.refresh(from: generation)
        try? leaseStore.reconcile(logins: leaseLogins, policies: currentPolicies)
        offerSelfTestIfNeeded()
        if device?.isJoined == true {
            // Josh approves sending the list in a panel beside his window.
            importedLoginsAwaitApproval = true
            notice = MirrorNotice(kind: .information,
                text: "Import complete. Your iPhone and other machines get the new list once you allow it.")
        } else {
            notice = MirrorNotice(kind: .information, text: "Import complete. Exported logins have been updated.")
        }
    }
}

@available(macOS 26.0, *)
extension MirrorAppModel {
    /// Only in a debug build, and only when launched with --import-made-up-logins.
    public func importMadeUpLoginsIfAsked() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--import-made-up-logins"), status == nil { await importMadeUpLogins() }
        #endif
    }
}

#if DEBUG
@available(macOS 26.0, *)
extension MirrorAppModel {
    /// For trying first run on a Mac whose Passwords holds real logins: the
    /// same import, with made-up example.com logins in place of the export.
    public func importMadeUpLogins() async {
        isImporting = true
        defer { isImporting = false; awaitingExport = false }
        let items = ["mail.example.com", "shop.example.com", "bank.example.net"].map { site in
            MirrorItem(id: UUID(), sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "made-up", accountID: Data("made-up".utf8),
                itemID: Data(site.utf8)), title: site, origins: ["https://\(site)"],
                credentials: [.password(userName: "josh@example.com", password: "made-up-password-for-\(site)")])
        }
        await importBatch(MirrorImportBatch(scope: .full, exportedAt: .now, exporterIdentifier: "made-up",
            exporterDisplayName: "Made-up logins", items: items, skippedCredentialCount: 0), hadExistingMirror: status != nil)
    }
}
#endif
