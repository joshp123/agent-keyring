#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringSealing
import AuthenticationServices
import Foundation
import LocalAuthentication
import OSLog

private let credentialExchangeLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "Import"
)

@available(macOS 26.0, *)
extension MacKeyringEngine {
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
            importSession.sendSelectiveImportEvent(.failExport(MessageCopy.exportSentNothing, sessionID: importSession.id))
            return
        }

        guard handledTokens.insert(token).inserted else {
            credentialExchangeLogger.notice("Ignored a duplicate import token")
            return
        }

        credentialExchangeLogger.info("Import token present")
        Task { await importCredentials(token: token) }
    }

    /// Opens the selective import flow from the main window (Copy Again / Add Passwords).
    public func openPasswordsCopyFlow() {
        categorySortingTask?.cancel()
        categorySortingTask = nil
        problem = nil
        importSession.sendSelectiveImportEvent(.openFlow)
        if enableBackgroundOnDeviceSorting {
            OnDeviceCategoryClassifier.shared.prewarm()
        }
    }

    /// "Open Apple Passwords". After five minutes with nothing arrived, the page says so;
    /// passwords that arrived first have already moved it on, so the late timer changes nothing.
    public func openPasswordsExport() {
        problem = nil
        guard importSession.sendSelectiveImportEvent(.beginExportWaiting) else { return }
        if enableBackgroundOnDeviceSorting {
            OnDeviceCategoryClassifier.shared.prewarm()
        }
        let sessionID = importSession.id
        let attemptID = importSession.exportAttemptID
        exportTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, self.importSession.id == sessionID else { return }
            self.importSession.sendSelectiveImportEvent(.exportTimedOut(attemptID: attemptID))
        }
        openPasswords()
    }

    /// Cancel on the main window's copy, or the copy ending: drops any unstaged import and brings the list back.
    public func closePasswordsCopy() {
        categorySortingTask?.cancel()
        categorySortingTask = nil
        problem = nil
        importSession.sendSelectiveImportEvent(.closeFlow)
    }

    /// Sends an event to the explicit selective-import state machine.
    @discardableResult
    public func sendImport(_ event: SelectiveImportEvent) -> Bool {
        switch event {
        case .continueFromChoose, .continueFromCategories, .switchToAllPasswords:
            clearProblem()
            if enableBackgroundOnDeviceSorting { OnDeviceCategoryClassifier.shared.prewarm() }
        case .switchToPickFew, .switchToCategories, .backToChoose, .backToCategories, .openChangeCategories, .addMorePasswords:
            clearProblem()
        case .reset, .closeFlow, .openFlow:
            categorySortingTask?.cancel()
            categorySortingTask = nil
        default:
            break
        }
        let changed = importSession.sendSelectiveImportEvent(event)
        if case .review = importSession.phase {
            startOnDeviceSortingIfNeeded(sessionID: importSession.id)
        } else {
            categorySortingTask?.cancel()
            categorySortingTask = nil
        }
        return changed
    }

    /// Drops an in-memory staged import without saving anything to disk, keychain or iCloud.
    public func cancelStagedImport(inFirstRun: Bool) {
        categorySortingTask?.cancel()
        categorySortingTask = nil
        problem = nil
        if inFirstRun {
            importSession.sendSelectiveImportEvent(.reset)
        } else {
            importSession.sendSelectiveImportEvent(.closeFlow)
        }
    }

    /// Toggles selection of one staged password in memory.
    public func toggleStagedImportItem(_ id: UUID) {
        importSession.sendSelectiveImportEvent(.toggleItem(id))
    }

    /// Includes all excluded banking, crypto and government passwords in the staged selection.
    public func includeAllSensitiveStagedItems() {
        importSession.sendSelectiveImportEvent(.includeAllSensitive)
    }

    /// Excludes all banking, crypto and government passwords in the staged selection.
    func excludeAllSensitiveStagedItems() {
        importSession.sendSelectiveImportEvent(.excludeAllSensitive)
    }

    /// Re-applies chosen categories to the already-exported in-memory batch (no re-export needed).
    public func reapplyCategoriesToStagedImport(_ categories: Set<ImportCategory>) {
        importSession.selectedCategories = categories
        importSession.sendSelectiveImportEvent(.continueFromCategories)
    }

    /// Saves ONLY the checked passwords from the in-memory staged import, drops the rest, and shows the receipt.
    @discardableResult
    public func commitStagedImport() async -> Bool {
        guard importSession.sendSelectiveImportEvent(.beginSave), let staged = importSession.staged else { return false }
        categorySortingTask?.cancel()
        categorySortingTask = nil
        let sessionID = importSession.id
        let hadExistingVault = status != nil
        let hadRealPasswords = (try? await store.loadCurrent())?.items.contains(where: { !$0.isTestPassword }) ?? false
        let batchToSave = staged.selectedBatch
        lastCopyChangedNothing = false

        guard let committed = await importBatchReturningCommittedIDs(batchToSave, hadExistingVault: hadExistingVault) else {
            importSession.sendSelectiveImportEvent(.failSave(sessionID: sessionID))
            return false
        }

        // Persist on-device classifications only for logins the user actually saved.
        if enableBackgroundOnDeviceSorting {
            let savedClassifications: [(host: String, title: String, category: ImportCategory)] = staged.items.compactMap { item in
                guard committed.sourceIDs.contains(item.id),
                      let category = item.category,
                      DomainClassifier.classify(item.item) == nil else {
                    return nil
                }
                return (host: item.host, title: item.item.title, category: category)
            }
            if !savedClassifications.isEmpty {
                OnDeviceCategoryClassifier.shared.remember(savedClassifications)
            }
        }

        let receipt = staged.makeReceipt(committedIDs: committed.sourceIDs, isReimport: hadRealPasswords)
        if hasOtherDevices {
            lastCopyChangedNothing = unsentChanges.total == 0
            Task { await publishChanges() }
        }
        return importSession.sendSelectiveImportEvent(.finishSave(receipt, sessionID: sessionID))
    }

    /// Adds a single manually entered password through the same encrypted vault pipeline.
    public func addManualPassword(
        website: String,
        account: String,
        password: String,
        totpSecret: String? = nil,
        rule: LoginRule = .ask,
        showReceipt: Bool = false
    ) async throws {
        guard importSession.sendSelectiveImportEvent(.beginManualSave) else {
            throw NSError(domain: "AgentKeyring.ManualAdd", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Another save is already in progress. Try again in a moment."
            ])
        }
        let sessionID = importSession.id
        let batch: LoginImportBatch
        do {
            batch = try ManualCredentialBuilder.buildBatch(
                website: website,
                account: account,
                password: password,
                totpSecret: totpSecret
            )
        } catch {
            importSession.sendSelectiveImportEvent(.failSave(sessionID: sessionID))
            throw error
        }

        guard let first = batch.items.first else {
            importSession.sendSelectiveImportEvent(.failSave(sessionID: sessionID))
            return
        }

        var ruleContext: LAContext?
        if rule == .automatic {
            do {
                ruleContext = try await confirmAlwaysAllowedManualPassword(first)
            } catch {
                importSession.sendSelectiveImportEvent(.failSave(sessionID: sessionID))
                throw error
            }
        }
        defer { ruleContext?.invalidate() }

        let hadExistingVault = status != nil
        let hadRealPasswords = (try? await store.loadCurrent())?.items.contains(where: { !$0.isTestPassword }) ?? false
        lastCopyChangedNothing = false
        guard let committed = await importBatchReturningCommittedIDs(batch, hadExistingVault: hadExistingVault) else {
            importSession.sendSelectiveImportEvent(.failSave(sessionID: sessionID))
            throw NSError(domain: "AgentKeyring.ManualAdd", code: 1, userInfo: [
                NSLocalizedDescriptionKey: importSession.problem ?? problem ?? MessageCopy.notLockedAway(hadEarlierCopy: hadExistingVault)
            ])
        }
        guard committed.sourceIDs.contains(first.id), let canonicalID = committed.canonicalIDs[first.id] else {
            importSession.sendSelectiveImportEvent(.failSave(sessionID: sessionID))
            throw NSError(domain: "AgentKeyring.ManualAdd", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "That login is currently Blocked in Passwords. Change its rule to Ask first to save a new password."
            ])
        }

        if let ruleContext, rule == .automatic {
            await accessControl.setRule(.automatic, for: [canonicalID], context: ruleContext)
            if let message = accessControl.errorMessage {
                importSession.sendSelectiveImportEvent(.failSave(sessionID: sessionID))
                throw NSError(domain: "AgentKeyring.ManualAdd", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
        } else if hasOtherDevices {
            lastCopyChangedNothing = unsentChanges.total == 0
            Task { await publishChanges() }
        }
        let receipt = showReceipt ? Self.manualPasswordReceipt(first, isReimport: hadRealPasswords) : nil
        importSession.sendSelectiveImportEvent(.finishManualSave(receipt, sessionID: sessionID))
    }

    /// Josh's Touch ID for a manually entered password saved Always Allowed, naming every computer it reaches.
    /// The held context signs the rule change; his cancel comes back as `CancellationError`.
    private func confirmAlwaysAllowedManualPassword(_ item: StoredVaultLogin) async throws -> LAContext {
        let context = LAContext()
        let computers = ["this Mac"] + (device?.members?.machines ?? [])
            .filter { $0.machineID != device?.ownMachineID }.map(\.label)
        let listed = computers.count > 1 ? computers.dropLast().joined(separator: ", ") + " and " + computers.last! : (computers.first ?? "this Mac")
        let site = DomainClassifier.primaryHost(origins: item.origins, title: item.title)
        do {
            try await confirmOwner(context, reason: "let agents on \(listed) use your \(site) password without asking")
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            context.invalidate()
            throw CancellationError()
        } catch {
            context.invalidate()
            throw error
        }
        return context
    }

    /// The receipt shown after one manually entered password is saved.
    private static func manualPasswordReceipt(_ item: StoredVaultLogin, isReimport: Bool) -> ImportReceipt {
        let site = SavedReceiptSite(
            displayName: DomainClassifier.displayName(origins: item.origins, title: item.title),
            host: DomainClassifier.primaryHost(origins: item.origins, title: item.title)
        )
        return ImportReceipt(filteredCount: 1, savedCount: 1, notSavedCount: 0, savedSites: [site], isReimport: isReimport)
    }

    /// "Agent Keyring isn't in the list?": the sheet that sends him to AutoFill settings.
    public func explainAllowExport() {
        importSession.sendSelectiveImportEvent(.openAllowExport)
    }

    /// Open AutoFill Settings: System Settings opens at AutoFill, where he turns on Agent Keyring.
    public func openAutoFillSettings() {
        Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() }
    }

    /// The app came to the front: if he turned Agent Keyring on in AutoFill, the sheet closes and he starts the export again.
    public func recheckAutoFill() {
        guard importSession.exportState == .allowExport else { return }
        Task {
            guard await ASCredentialIdentityStore.shared.state().isEnabled else { return }
            _ = importSession.sendSelectiveImportEvent(.closeAllowExport)
        }
    }

    /// Cancel on the AutoFill sheet: back to the guide.
    public func closeAllowExport() {
        importSession.sendSelectiveImportEvent(.closeAllowExport)
    }

    /// The test password only, for now: a copy of nothing, which brings the
    /// test password if no copy has yet. Nothing to send if one has.
    public func useTestPassword() async {
        if (try? await store.loadCurrent())?.items.contains(where: \.isTestPassword) != true {
            guard await importBatch(LoginImportBatch(scope: .unknown, exportedAt: .now, exporterIdentifier: StoredVaultLogin.testPasswordSource,
                exporterDisplayName: "Test password", items: [], skippedCredentialCount: 0), hadExistingVault: status != nil)
            else { return }
        }
        closePasswordsCopy()
        sendFirstRunEvent(.useTestPasswordOnly)
    }

    static func launchApplePasswords(failed: @escaping @MainActor @Sendable () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") else { return failed() }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            Task { @MainActor in failed() }
        }
    }

    public func openPasswords() {
        let sessionID = importSession.id
        openApplePasswords { [weak self] in
            self?.importSession.sendSelectiveImportEvent(.failExport(MessageCopy.passwordsWontOpen, sessionID: sessionID))
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
        let sessionID = importSession.id
        guard importSession.sendSelectiveImportEvent(.beginImporting(sessionID: sessionID)) else { return }

        credentialExchangeLogger.info("Credential import started")

        let hadExistingVault = status != nil
        let exportedData: ASExportedCredentialData
        do {
            exportedData = try await credentialImporter.importCredentials(token: token)
            credentialExchangeLogger.info("Apple credential import completed")
        } catch {
            let failure = CredentialImportFailure(
                error: error,
                hadExistingVault: hadExistingVault
            )
            credentialExchangeLogger.error(
                "Credential transfer failed [\(failure.diagnostic, privacy: .public)]"
            )
            importSession.sendSelectiveImportEvent(.failExport(failure.message, sessionID: sessionID))
            KeyringDiagnosticLog.mac.noteDeviceEvent("copy", "failed", ["reason": failure.diagnostic])
            return
        }

        guard importSession.id == sessionID else {
            credentialExchangeLogger.notice("Dropped credential transfer for cancelled or superseded session")
            return
        }

        // Apple's Credential Exchange payload does not say whether the user chose
        // "Export Selected Item(s)" or "Export All Items". Hold the incoming batch
        // strictly in memory for offline review so nothing is written to keychain,
        // disk or iCloud until the user explicitly confirms Save.
        let copied = mapper.map(exportedData, scope: .selected)
        guard !copied.items.isEmpty else {
            let onlyPasskeys = (copied.skippedCredentialSummary?.passkeyCount ?? 0) > 0
            let message = onlyPasskeys ? MessageCopy.exportOnlyPasskeys : MessageCopy.exportSentNothing
            importSession.sendSelectiveImportEvent(.failExport(message, sessionID: sessionID))
            return
        }
        stageIncomingBatch(copied, sessionID: sessionID)
        // He is in Passwords: the Dock icon bounces once; the window is never pushed in front.
        if !NSApplication.shared.isActive { NSApplication.shared.requestUserAttention(.informationalRequest) }
    }

    /// Stages a mapped Apple Passwords batch strictly in memory and opens Review & Keep.
    /// Does not write to disk, keychain or iCloud. Starts background Apple Intelligence
    /// sorting for any unlisted sites without blocking Save.
    public func stageIncomingBatch(_ copied: LoginImportBatch, sessionID: UUID? = nil) {
        let targetSession = sessionID ?? importSession.id
        guard importSession.sendSelectiveImportEvent(.stageIncoming(copied, sessionID: targetSession)) else { return }
        problem = nil
        categorySortingTask?.cancel()
        categorySortingTask = nil
        startOnDeviceSortingIfNeeded(sessionID: targetSession)
    }

    private func startOnDeviceSortingIfNeeded(sessionID targetSession: UUID) {
        guard enableBackgroundOnDeviceSorting,
              categorySortingTask == nil,
              case let .review(staged) = importSession.phase
        else { return }

        let unlisted = staged.unsortedItems.map { item in
            OnDeviceClassificationItem(id: item.id, host: item.host, title: item.item.title)
        }
        guard !unlisted.isEmpty, OnDeviceCategoryClassifier.shared.isAvailable else { return }

        importSession.sendSelectiveImportEvent(.beginOnDeviceSorting(count: unlisted.count, sessionID: targetSession))
        categorySortingTask = Task { @MainActor [weak self] in
            defer { self?.categorySortingTask = nil }
            // Never persist classifications to disk while an export is still staged and uncommitted.
            let stream = OnDeviceCategoryClassifier.shared.classifyStreaming(unlisted, persistCache: false)
            for await result in stream {
                guard !Task.isCancelled, let self, self.importSession.id == targetSession else { return }
                self.importSession.sendSelectiveImportEvent(.applyOnDeviceCategory(result.category, ids: result.ids, sessionID: targetSession))
            }
            guard !Task.isCancelled, let self, self.importSession.id == targetSession else { return }
            self.importSession.sendSelectiveImportEvent(.finishOnDeviceSorting(sessionID: targetSession))
        }
    }

    /// Background pass to classify and cache any unlisted saved vault logins for the Passwords sidebar.
    func sortUnlistedVaultLoginsIfNeeded() {
        guard enableBackgroundOnDeviceSorting,
              vaultCategorySortingTask == nil,
              OnDeviceCategoryClassifier.shared.isAvailable
        else { return }

        let unlisted: [OnDeviceClassificationItem] = accessControl.rows.compactMap { row in
            let site = row.website.isEmpty ? row.title : row.website
            if DomainClassifier.classify(site: site) != nil { return nil }
            if OnDeviceCategoryClassifier.shared.cachedCategory(forSite: site) != nil { return nil }
            return OnDeviceClassificationItem(id: row.id, host: site, title: row.title)
        }
        guard !unlisted.isEmpty else { return }

        vaultCategorySortingTask = Task { @MainActor [weak self] in
            defer { self?.vaultCategorySortingTask = nil }
            let stream = OnDeviceCategoryClassifier.shared.classifyStreaming(unlisted)
            var updated = false
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                updated = true
                self.vaultCategoriesRevision &+= 1
            }
            if updated, let self, !Task.isCancelled {
                self.vaultCategoriesRevision &+= 1
            }
        }
    }

    /// True once the import is sealed and saved.
    @discardableResult
    func importBatch(_ copied: LoginImportBatch, hadExistingVault: Bool) async -> Bool {
        await importBatchReturningCommittedIDs(copied, hadExistingVault: hadExistingVault) != nil
    }

    /// Seals and saves `copied`, returning both the original `StoredVaultLogin.id`s whose secrets were committed
    /// (excluding Blocked logins and the synthetic test password) and the mapping to canonical login UUIDs.
    func importBatchReturningCommittedIDs(
        _ copied: LoginImportBatch,
        hadExistingVault: Bool
    ) async -> (sourceIDs: Set<UUID>, canonicalIDs: [UUID: UUID])? {
        let saved: (items: Int, committedSourceIDs: Set<UUID>, canonicalBySource: [UUID: UUID])
        do {
            // Every copy keeps one test password, sealed again with the rest.
            let importBatch = copied.items.contains(where: \.isTestPassword) ? copied
                : LoginImportBatch(scope: copied.scope, exportedAt: copied.exportedAt, exporterIdentifier: copied.exporterIdentifier,
                    exporterDisplayName: copied.exporterDisplayName, items: copied.items + [StoredVaultLogin.testPassword],
                    skippedCredentialCount: copied.skippedCredentialCount, skippedCredentialSummary: copied.skippedCredentialSummary)
            credentialExchangeLogger.info(
                "Mapped \(importBatch.items.count, privacy: .public) items; skipped \(importBatch.skippedCredentialCount, privacy: .public) unsupported credentials"
            )
            let keys = try macKeys()
            // Read, merge and save in one turn of the catalogue's serializer: a peer's vault or catalogue taken
            // meanwhile is merged in, never written over by a merge of the list as it was before.
            let mergeAndSave: @MainActor () async throws -> (items: Int, committedSourceIDs: Set<UUID>, canonicalBySource: [UUID: UUID]) = { [self] in
                let previous = try await self.store.loadCurrent()
                let rulesBefore = self.accessControl.entries
                let merged = try self.merger.mergeImportedSnapshot(previous: previous, importBatch: importBatch, rules: rulesBefore, actor: keys.deviceKeyID)
                let rules = merged.rules
                try self.accessControl.adopt(rules)
                let kept = Set(merged.snapshot.items.filter { !merged.sealing.contains($0.id) && ($0.imports == nil || $0.liveImport != nil) }
                    .map(\.id.uuidString))
                let ownMachineID = keys.machineID
                let current = self.accessControl.entries
                let blockedNow = Set(current.filter { $0.value.rule == .blocked }.keys)
                let snapshot = merged.snapshot.deletingSecrets(of: blockedNow.subtracting(rules.filter { $0.value.rule == .blocked }.keys),
                    at: merged.version + 1)
                let blocked = Set(blockedNow.map(\.uuidString))
                let fresh = snapshot.items.filter { merged.sealing.contains($0.id) && !blockedNow.contains($0.id) }
                let signed = Dictionary((self.device?.catalogue?.logins ?? []).map { ($0.loginID, $0.version) }, uniquingKeysWith: { first, _ in first })
                let incoming = try fresh.flatMap { item in
                    try self.sealCopies(of: item.secret, version: merged.version, automatic: current[item.id]?.rule == .automatic)
                }
                try await self.store.save(snapshot) { existing in
                    let preserved = existing.filter { copy in
                        !blocked.contains(copy.loginID)
                            && (kept.contains(copy.loginID) || (copy.openerID != ownMachineID && signed[copy.loginID] == copy.version))
                    }
                    return preserved + incoming
                }
                self.status = snapshot.safeStatus
                self.leaseLogins = snapshot.metadata.candidates

                // Map committed (non-blocked, non-test) canonical IDs back to the caller's incoming item IDs.
                let committedCanonical = Set(snapshot.items.filter { !blockedNow.contains($0.id) && !$0.isTestPassword }.map(\.id))
                let assignedIDs = LoginIdentity.ids(for: copied.items)
                var committedSourceIDs: Set<UUID> = []
                var canonicalBySource: [UUID: UUID] = [:]
                for (item, assigned) in zip(copied.items, assignedIDs) where committedCanonical.contains(assigned) {
                    committedSourceIDs.insert(item.id)
                    canonicalBySource[item.id] = assigned
                }
                return (snapshot.items.count, committedSourceIDs, canonicalBySource)
            }
            if let device {
                saved = try await device.withSerializedCatalogue(mergeAndSave)
            } else {
                saved = try await mergeAndSave()
            }
            device?.cloudSync.pushCloudSoon()
        } catch {
            credentialExchangeLogger.error("Sealing the import failed: \(String(describing: error), privacy: .public)")
            let message = MessageCopy.notLockedAway(hadEarlierCopy: hadExistingVault)
            problem = message
            importSession.problem = message
            return nil
        }

        credentialExchangeLogger.info("Saved encrypted vault with \(saved.items, privacy: .public) items")
        await accessControl.refresh(fromMetadata: try? await store.loadCurrentMetadata())
        sortUnlistedVaultLoginsIfNeeded()
        await noteMissingAutomaticCopies()
        problem = nil
        importSession.problem = nil
        return (saved.committedSourceIDs, saved.canonicalBySource)
    }
}
#endif
