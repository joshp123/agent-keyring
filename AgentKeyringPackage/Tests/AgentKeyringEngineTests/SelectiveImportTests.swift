// Written by AI on 2026.11.25 by model gemini-4-neon.
//
// End-to-end tests for offline domain classification, bundled offline favicon
// lookup, manual password entry, and every import / don't-import flow.

import AgentKeyringApprovalUI
@testable import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Testing

struct SelectiveImportTests {
    private func makeItem(site: String, title: String? = nil, account: String = "alex@example.com") -> StoredVaultLogin {
        StoredVaultLogin(
            id: UUID(),
            sourceIdentity: LoginSourceIdentity(
                exporterIdentifier: "com.apple.Passwords",
                accountID: Data("acc".utf8),
                itemID: Data("\(site)|\(account)".utf8)
            ),
            title: title ?? site,
            origins: ["https://\(site)"],
            credentials: [.password(userName: account, password: "pw-\(site)")]
        )
    }

    private func makeBatch(_ items: [StoredVaultLogin]) -> LoginImportBatch {
        LoginImportBatch(
            scope: .selected,
            exportedAt: .now,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: items,
            skippedCredentialCount: 0
        )
    }

    @MainActor
    private func makeTestModel(in dir: URL) throws -> (MacKeyringEngine, MacVaultFileStore, UserDefaults, String) {
        let store = MacVaultFileStore(directory: dir.appending(path: "logins"))
        let leaseStore = CredentialLeaseStore(persistence: LeasePersistence(directory: dir.appending(path: "leases")))
        final class MemoryPolicyBox: @unchecked Sendable { var data: Data? }
        let box = MemoryPolicyBox()
        let policyStore = LoginRuleStore(read: { box.data }, write: { box.data = $0 })
        let suite = "SelectiveImportTests.\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: suite)!
        let model = MacKeyringEngine(
            store: store,
            accessControl: CredentialAccessController(store: policyStore),
            leaseStore: leaseStore,
            settings: settings
        )
        model.enableBackgroundOnDeviceSorting = false
        let testKeys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        model.installTestingKeys(testKeys)
        return (model, store, settings, suite)
    }

    private func realSavedTitles(in store: MacVaultFileStore) async throws -> Set<String> {
        guard let generation = try await store.loadCurrent() else { return [] }
        return Set(generation.items.filter { !$0.isTestPassword }.map(\.title))
    }

    @MainActor
    @Test("Path A Pick a Few: saves only checked items, drops unchecked ones, and records sealed copies")
    func pathAPickFewCommitOnlyChecked() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-pathA-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        model.sendImport(.selectPath(.pickFew))
        model.stageIncomingBatch(makeBatch([
            makeItem(site: "github.com"),
            makeItem(site: "openai.com"),
            makeItem(site: "amazon.com"),
        ]))

        // Nothing written before Save
        #expect(try await store.loadCurrent() == nil)
        #expect(try await store.sealed().isEmpty)

        // Uncheck Amazon before saving
        let amazonID = try #require(model.importSession.staged?.items.first(where: { $0.item.title == "amazon.com" })?.id)
        model.toggleStagedImportItem(amazonID)
        #expect(model.importSession.staged?.selectedCount == 2)

        let saved = await model.commitStagedImport()
        #expect(saved)
        #expect(model.importSession.staged == nil)
        #expect(try await realSavedTitles(in: store) == ["github.com", "openai.com"])
        #expect(try await store.sealed().count == 3) // 2 kept + 1 synthetic test password
        if case let .receipt(receipt) = model.importSession.step {
            #expect(receipt.filteredCount == 3)
            #expect(receipt.savedCount == 2)
            #expect(receipt.notSavedCount == 1)
        } else {
            Issue.record("Expected receipt step after commitStagedImport")
        }
    }

    @MainActor
    @Test("Accidental export-all on Path A stays in memory; Cancel writes nothing to the vault")
    func consentBeforeWriteCancelDropsBatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        model.sendImport(.selectPath(.pickFew))
        let items = (1...20).map { makeItem(site: "site\($0).example") } + [makeItem(site: "wise.com"), makeItem(site: "hmrc.gov.uk")]
        model.stageIncomingBatch(makeBatch(items))

        #expect(try await store.loadCurrent() == nil)
        #expect(try await store.sealed().isEmpty)
        #expect(model.status == nil)
        #expect(model.importSession.step == .review)
        #expect(model.importSession.staged?.excludedSensitiveItems.count == 2)

        // Unchecking everything blocks Save with zero writes
        for id in Array(model.importSession.staged?.selectedIDs ?? []) {
            model.toggleStagedImportItem(id)
        }
        #expect(await model.commitStagedImport() == false)
        #expect(try await store.loadCurrent() == nil)

        // Cancel drops the staged batch cleanly with zero persistence
        model.cancelStagedImport(inFirstRun: true)
        #expect(model.importSession.staged == nil)
        #expect(model.importSession.step == .choose)
        #expect(try await store.loadCurrent() == nil)
        #expect(try await store.sealed().isEmpty)
        #expect(model.status == nil)
    }

    @MainActor
    @Test("Path B Pick by Category: re-filters in memory and saves only chosen category without sensitive items")
    func pathBCategoryRefilterAndCommit() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-pathB-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        model.sendImport(.selectPath(.byCategory))
        model.importSession.selectedCategories = [.codingCloud, .aiTools]
        model.stageIncomingBatch(makeBatch([
            makeItem(site: "github.com"),
            makeItem(site: "console.aws.amazon.com"),
            makeItem(site: "claude.ai"),
            makeItem(site: "amazon.co.uk"),
            makeItem(site: "wise.com"),
            makeItem(site: "my.1password.com"),
        ]))
        #expect(model.importSession.staged?.selectedCount == 3)

        // Re-filter strictly in memory to Coding & Cloud only
        model.reapplyCategoriesToStagedImport([.codingCloud])
        #expect(model.importSession.staged?.selectedCount == 2)
        #expect(try await store.loadCurrent() == nil)

        let saved = await model.commitStagedImport()
        #expect(saved)
        #expect(try await realSavedTitles(in: store) == ["github.com", "console.aws.amazon.com"])
        #expect(try await store.sealed().count == 3)
    }

    @MainActor
    @Test("Path C All Passwords: excludes sensitive by default, and includes them only after explicit opt-in")
    func pathCAllPasswordsSensitiveGuardAndOptIn() async throws {
        let dir1 = FileManager.default.temporaryDirectory.appending(path: "ak-pathC1-\(UUID().uuidString)")
        let dir2 = FileManager.default.temporaryDirectory.appending(path: "ak-pathC2-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }
        let batch = makeBatch([
            makeItem(site: "github.com"),
            makeItem(site: "amazon.com"),
            makeItem(site: "wise.com"),
            makeItem(site: "my.1password.com"),
        ])

        // Default Path C commit excludes sensitive logins
        let (model1, store1, settings1, suite1) = try makeTestModel(in: dir1)
        defer { settings1.removePersistentDomain(forName: suite1) }
        model1.sendImport(.selectPath(.allPasswords))
        model1.stageIncomingBatch(batch)
        #expect(await model1.commitStagedImport())
        #expect(try await realSavedTitles(in: store1) == ["github.com", "amazon.com"])

        // Explicit "Include All Sensitive" opt-in saves all 4
        let (model2, store2, settings2, suite2) = try makeTestModel(in: dir2)
        defer { settings2.removePersistentDomain(forName: suite2) }
        model2.sendImport(.selectPath(.allPasswords))
        model2.stageIncomingBatch(batch)
        model2.includeAllSensitiveStagedItems()
        #expect(await model2.commitStagedImport())
        #expect(try await realSavedTitles(in: store2) == ["github.com", "amazon.com", "wise.com", "my.1password.com"])
    }

    @MainActor
    @Test("Later re-import and manual add merge with existing vault; cancelling preserves existing passwords untouched")
    func laterReimportCancelAndMerge() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        // Initial import: GitHub
        model.sendImport(.selectPath(.pickFew))
        model.stageIncomingBatch(makeBatch([makeItem(site: "github.com")]))
        #expect(await model.commitStagedImport())
        #expect(try await realSavedTitles(in: store) == ["github.com"])

        // Later import cancelled: must NOT wipe or modify GitHub
        model.openPasswordsCopyFlow()
        model.stageIncomingBatch(makeBatch([makeItem(site: "openai.com"), makeItem(site: "wise.com")]))
        model.cancelStagedImport(inFirstRun: false)
        #expect(!model.importSession.isFlowOpen)
        #expect(try await realSavedTitles(in: store) == ["github.com"])

        // Later import committed (keep OpenAI, drop Wise): merges with GitHub
        model.openPasswordsCopyFlow()
        model.stageIncomingBatch(makeBatch([makeItem(site: "openai.com"), makeItem(site: "wise.com")]))
        let wiseID = try #require(model.importSession.staged?.items.first(where: { $0.item.title == "wise.com" })?.id)
        model.toggleStagedImportItem(wiseID)
        #expect(await model.commitStagedImport())
        #expect(try await realSavedTitles(in: store) == ["github.com", "openai.com"])

        // Manual password add merges on top without wiping existing items
        try await model.addManualPassword(
            website: "cloudflare.com",
            account: "alex@example.com",
            password: "correct-horse-battery",
            totpSecret: "JBSWY3DPEHPK3PXP",
            showReceipt: true
        )
        #expect(try await realSavedTitles(in: store) == ["github.com", "openai.com", "cloudflare.com"])
    }

    @MainActor
    @Test("Skip import (I'll do this later) saves zero real passwords and advances first run past copy")
    func skipImportUsesTestPasswordOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        model.sendFirstRunEvent(.getStarted)
        let practiceID = UUID()
        model.sendFirstRunEvent(.sendPractice(id: practiceID))
        model.sendFirstRunEvent(.practiceApproved(id: practiceID))
        model.sendFirstRunEvent(.continueOn) // -> .privacy
        model.sendFirstRunEvent(.continueOn) // -> .copy
        #expect(model.firstRun.step == .copy)

        await model.useTestPassword()
        #expect(try await realSavedTitles(in: store).isEmpty)
        #expect(try await store.loadCurrent()?.items.contains(where: \.isTestPassword) == true)
        #expect(!model.importSession.isFlowOpen)
        #expect(model.firstRun.step == .connectAgent(.notTried))
    }

    @MainActor
    @Test("Explicit import session preserves manual edits across Categories <-> All without re-exporting and drops late transfers after Cancel")
    func explicitImportSessionOverridesNoReexportAndStaleSessionDrop() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        model.sendImport(.selectPath(.byCategory))
        model.importSession.selectedCategories = [.codingCloud, .aiTools]
        let sessionBeforeCancel = model.importSession.id

        let batch = makeBatch([
            makeItem(site: "github.com"),
            makeItem(site: "openai.com"),
            makeItem(site: "amazon.co.uk"),
            makeItem(site: "wise.com"),
            makeItem(site: "my.1password.com", account: "personal@example.com"),
            makeItem(site: "my.1password.com", account: "work@example.com"),
        ])
        model.stageIncomingBatch(batch, sessionID: sessionBeforeCancel)

        let staged1 = try #require(model.importSession.staged)
        // 2 selected (GitHub, OpenAI) + 1 other excluded (Amazon) + 3 sensitive excluded (Wise, 2x 1Password) == 6
        #expect(staged1.selectedCount == 2)
        #expect(staged1.otherExcludedItems.count == 1)
        #expect(staged1.excludedSensitiveItems.count == 3)
        #expect(staged1.selectedCount + staged1.otherExcludedItems.count + staged1.excludedSensitiveItems.count == staged1.totalCount)

        // Deduplicated sensitive names group 2x 1Password cleanly while preserving exact count 3
        #expect(staged1.groupedExcludedSensitiveNames.contains("1Password (2)"))

        // Uncheck GitHub and opt in Wise explicitly
        let githubID = try #require(staged1.items.first(where: { $0.item.title == "github.com" })?.id)
        let wiseID = try #require(staged1.items.first(where: { $0.item.title == "wise.com" })?.id)
        model.sendImport(.toggleItem(githubID))
        model.sendImport(.toggleItem(wiseID))

        // Back -> Choose -> All Passwords must reuse staged batch in memory (no exportBridge!) and preserve manual edits
        model.sendImport(.backToChoose)
        model.sendImport(.selectPath(.allPasswords))
        model.sendImport(.continueFromChoose)
        #expect(model.importSession.step == .review)
        let stagedAll = try #require(model.importSession.staged)
        #expect(!stagedAll.selectedIDs.contains(githubID)) // manual uncheck survived
        #expect(stagedAll.selectedIDs.contains(wiseID))    // manual sensitive opt-in survived
        #expect(stagedAll.selectedCount == 3)              // OpenAI, Amazon, Wise

        // Switch back to Categories via live toggle: manual edits still survive
        model.sendImport(.toggleCategory(.aiTools)) // toggles off aiTools -> only codingCloud left
        let stagedCat = try #require(model.importSession.staged)
        #expect(!stagedCat.selectedIDs.contains(githubID)) // still manually unchecked
        #expect(stagedCat.selectedIDs.contains(wiseID))    // still manually opted in
        #expect(stagedCat.selectedCount == 1)              // Wise alone

        // Commit and verify receipt carries real host
        #expect(await model.commitStagedImport())
        if case let .receipt(receipt) = model.importSession.step {
            #expect(receipt.savedCount == 1)
            #expect(receipt.savedSites.first?.host == "wise.com")
        } else {
            Issue.record("Expected receipt after commit")
        }

        // Cancel rotates session ID so a late incoming transfer for the old session is dropped
        model.sendImport(.addMorePasswords)
        let cancelledID = model.importSession.id
        model.cancelStagedImport(inFirstRun: true)
        model.stageIncomingBatch(batch, sessionID: cancelledID)
        #expect(model.importSession.staged == nil)
        #expect(model.importSession.step == .choose)
        #expect(try await realSavedTitles(in: store) == ["wise.com"])
    }

    @MainActor
    @Test("Manual re-add updates the existing login in place instead of duplicating")
    func manualReaddUpdatesInPlace() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        // Manual add + manual re-add of same (host, account) updates in place (count stays 1)
        try await model.addManualPassword(website: "cloudflare.com", account: "dev@example.com", password: "pw1")
        try await model.addManualPassword(website: "cloudflare.com", account: "dev@example.com", password: "pw2")
        #expect(try await realSavedTitles(in: store) == ["cloudflare.com"])
    }

    @Test("Imported one at a time, a renamed login and a new password keep its ID and Automatic; another login for the same account starts at Ask")
    func oneAtATimeImportsKeepEachLogin() throws {
        let created = Date(timeIntervalSinceReferenceDate: 538_768_074.380_438)
        func github(title: String, password: String, created: Date = created, modified: TimeInterval) -> StoredVaultLogin {
            StoredVaultLogin(id: UUID(), sourceIdentity: LoginSourceIdentity(exporterIdentifier: "com.apple.Passwords",
                    accountID: Data(UUID().uuidString.utf8), itemID: Data(UUID().uuidString.utf8)),
                createdAt: created, lastModifiedAt: Date(timeIntervalSinceReferenceDate: modified), title: title,
                origins: ["https://github.com"], credentials: [.password(userName: "dev@example.com", password: password)])
        }
        let merger = VaultSnapshotMerger()
        let first = try merger.mergeImportedSnapshot(previous: nil, importBatch: makeBatch([github(title: "GitHub", password: "p1", modified: 1)]), actor: "mac")
        let id = try #require(first.snapshot.items.first?.id)
        let automatic = [id: LoginRuleTimestampEntry(.automatic, updatedAtMs: 5, actor: "mac")]

        let renamed = try merger.mergeImportedSnapshot(previous: first.snapshot.redacted,
            importBatch: makeBatch([github(title: "GitHub (work)", password: "p1", modified: 2)]), rules: automatic, actor: "mac")
        #expect(renamed.snapshot.items.map(\.id) == [id])
        #expect(renamed.snapshot.items.first?.title == "GitHub (work)")
        #expect(renamed.rules[id]?.rule == .automatic)

        let rotated = try merger.mergeImportedSnapshot(previous: renamed.snapshot.redacted,
            importBatch: makeBatch([github(title: "GitHub (work)", password: "p2", modified: 3)]), rules: renamed.rules, actor: "mac")
        #expect(rotated.snapshot.items.map(\.id) == [id])
        #expect(rotated.snapshot.items.first?.credentials == [.password(userName: "dev@example.com", password: "p2")])
        #expect(rotated.rules[id]?.rule == .automatic)
        #expect(rotated.sealing == [id])

        let another = try merger.mergeImportedSnapshot(previous: rotated.snapshot.redacted,
            importBatch: makeBatch([github(title: "GitHub", password: "p3", created: created.addingTimeInterval(0.000_2), modified: 4)]),
            rules: rotated.rules, actor: "mac")
        #expect(another.snapshot.items.count == 2)
        let otherID = try #require(another.snapshot.items.first { $0.id != id }?.id)
        #expect(another.rules[id]?.rule == .automatic)
        #expect(another.rules[otherID]?.rule ?? .ask == .ask)
    }

    @MainActor
    @Test("First-run manual add transitions to receipt, preserves password newlines, rejects HOTP/9-digit TOTP, and marks re-imports")
    func manualAddReceiptAndValidationAndReimport() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-man-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        // First-run manual add with showReceipt: true must transition straight into .receipt (not stay stuck on pickFew)
        model.sendImport(.selectPath(.pickFew))
        model.sendImport(.continueFromChoose)
        #expect(model.importSession.step == .pickFew)

        try await model.addManualPassword(
            website: "cloudflare.com",
            account: "dev@example.com",
            password: "\nsecret-pass\n",
            totpSecret: "JBSWY3DPEHPK3PXP",
            showReceipt: true
        )
        if case let .receipt(receipt) = model.importSession.step {
            #expect(receipt.savedCount == 1)
            #expect(!receipt.isReimport)
            #expect(receipt.savedSites.first?.host == "cloudflare.com")
        } else {
            Issue.record("Expected .receipt after first-run manual add, got \(model.importSession.step)")
        }
        #expect(!model.importSession.isSaving)

        // Password newlines must be preserved verbatim; HOTP and 9-digit TOTP must be rejected
        let batch = try ManualCredentialBuilder.buildBatch(website: "example.com", account: "a", password: "\nkeep-me\n")
        if case let .password(_, pw) = batch.items.first?.credentials.first {
            #expect(pw == "\nkeep-me\n")
        } else {
            Issue.record("Expected password credential")
        }
        #expect(throws: ManualCredentialError.invalidTwoFactorKey) {
            _ = try ManualCredentialBuilder.buildBatch(website: "example.com", account: "a", password: "pw", totpSecret: "otpauth://hotp/Test?secret=JBSWY3DPEHPK3PXP")
        }
        #expect(throws: ManualCredentialError.invalidTwoFactorKey) {
            _ = try ManualCredentialBuilder.buildBatch(website: "example.com", account: "a", password: "pw", totpSecret: "otpauth://totp/Test?secret=JBSWY3DPEHPK3PXP&digits=9")
        }

        // Subsequent staged import after real passwords exist must set receipt.isReimport == true
        model.sendImport(.addMorePasswords)
        model.sendImport(.selectPath(.byCategory))
        model.importSession.selectedCategories = [.codingCloud]
        let sessionID = model.importSession.id
        model.stageIncomingBatch(makeBatch([makeItem(site: "github.com"), makeItem(site: "amazon.co.uk")]), sessionID: sessionID)
        #expect(await model.commitStagedImport())
        if case let .receipt(reimportReceipt) = model.importSession.step {
            #expect(reimportReceipt.isReimport)
            #expect(reimportReceipt.savedCount == 1)
            #expect(reimportReceipt.notSavedCount == 1)
        } else {
            Issue.record("Expected re-import receipt")
        }

        // MacVaultFileStore generation pointer keeps current generation atomic and readable on reload
        let reloaded = try await store.loadCurrent()
        #expect(reloaded?.items.contains(where: { $0.title == "cloudflare.com" }) == true)
        #expect(reloaded?.items.contains(where: { $0.title == "github.com" }) == true)
    }

    @MainActor
    @Test("Background on-device sorting updates categories live, preserves manual overrides, and never blocks Save")
    func backgroundOnDeviceSortingStreamsAndPreservesOverrides() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-ai-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, store, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        model.sendImport(.selectPath(.byCategory))
        model.importSession.selectedCategories = [.codingCloud]
        let sessionID = model.importSession.id

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let known = makeItem(site: "github.com")
        let unlistedCode = makeItem(site: "private-ci-\(suffix).example")
        let unlistedManualOff = makeItem(site: "private-git-\(suffix).example")
        let unlistedBank = makeItem(site: "small-coop-\(suffix).example")

        model.stageIncomingBatch(makeBatch([known, unlistedCode, unlistedManualOff, unlistedBank]), sessionID: sessionID)

        // Immediately after staging: github.com is selected, 3 unlisted items start in Other (unticked).
        let initial = try #require(model.importSession.staged)
        #expect(initial.selectedCount == 1)
        #expect(initial.unsortedItems.count == 3)

        // Begin background sorting; Save must remain allowed immediately.
        #expect(model.sendImport(.beginOnDeviceSorting(count: 3, sessionID: sessionID)))
        #expect(model.importSession.staged?.sortingRemainingCount == 3)

        // User manually toggles unlistedManualOff on then off? Toggle unlistedManualOff explicitly to false after it would match:
        // First mark unlistedManualOff as manually overridden to false by toggling it after switching, or toggle it to true now.
        model.sendImport(.toggleItem(unlistedManualOff.id))
        #expect(model.importSession.staged?.selectedIDs.contains(unlistedManualOff.id) == true)

        // Stream in Apple Intelligence results one by one.
        #expect(model.sendImport(.applyOnDeviceCategory(.codingCloud, ids: [unlistedCode.id], sessionID: sessionID)))
        #expect(model.importSession.staged?.sortingRemainingCount == 2)
        #expect(model.importSession.staged?.selectedIDs.contains(unlistedCode.id) == true)

        // Manual user tick on unlistedManualOff survives even when Apple Intelligence returns .other.
        #expect(model.sendImport(.applyOnDeviceCategory(.other, ids: [unlistedManualOff.id], sessionID: sessionID)))
        #expect(model.importSession.staged?.sortingRemainingCount == 1)
        #expect(model.importSession.staged?.selectedIDs.contains(unlistedManualOff.id) == true)

        // Sensitive result moves item to Sensitive and stays excluded.
        #expect(model.sendImport(.applyOnDeviceCategory(.sensitive, ids: [unlistedBank.id], sessionID: sessionID)))
        #expect(model.importSession.staged?.sortingRemainingCount == 0)
        #expect(model.importSession.staged?.excludedSensitiveItems.map(\.id) == [unlistedBank.id])

        // Stale session ID is ignored.
        #expect(!model.sendImport(.applyOnDeviceCategory(.shopping, ids: [unlistedCode.id], sessionID: UUID())))

        // Save succeeds even if sorting is still running (simulate remaining count > 0).
        #expect(model.sendImport(.beginOnDeviceSorting(count: 2, sessionID: sessionID)))
        #expect(await model.commitStagedImport())
        #expect(try await realSavedTitles(in: store) == ["github.com", "private-ci-\(suffix).example", "private-git-\(suffix).example"])
    }

    @MainActor
    @Test("SelectiveImportSession drops staged data on close/finish and ignores late sorting during saving")
    func sessionDropsStagedDataAndIgnoresLateSorting() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-phase-invariants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, _, settings, suite) = try makeTestModel(in: dir)
        defer { settings.removePersistentDomain(forName: suite) }

        model.sendImport(.openFlow)
        let sessionID = model.importSession.id
        let known = makeItem(site: "github.com")
        let unlisted = makeItem(site: "private-ci.example")
        model.stageIncomingBatch(makeBatch([known, unlisted]), sessionID: sessionID)
        #expect(model.sendImport(.beginOnDeviceSorting(count: 1, sessionID: sessionID)))

        // Leaving review for categories keeps the unsorted count, so switching to All Passwords
        // mid-sorting never ticks unresolved rows before classification resumes.
        #expect(model.sendImport(.openChangeCategories))
        #expect(model.importSession.staged?.sortingRemainingCount == 1)

        // Switching to All Passwords while sorting is pending leaves unresolved rows unticked.
        #expect(model.sendImport(.switchToAllPasswords))
        let pendingRow = try #require(model.importSession.staged?.items.first(where: { $0.id == unlisted.id }))
        #expect(model.importSession.staged?.isSelected(pendingRow) == false)
        #expect(model.sendImport(.openChangeCategories))

        // Returning to .review and entering .saving freezes staged and ignores late sorting events.
        #expect(model.sendImport(.continueFromCategories))
        #expect(model.sendImport(.beginSave))
        if case .saving = model.importSession.phase {
        } else {
            Issue.record("Expected .saving phase")
        }
        #expect(!model.sendImport(.applyOnDeviceCategory(.codingCloud, ids: [unlisted.id], sessionID: sessionID)))
        #expect(!model.sendImport(.finishOnDeviceSorting(sessionID: sessionID)))
        #expect(model.importSession.staged?.items.first(where: { $0.id == unlisted.id })?.category == nil)

        // Finishing save transitions to .receipt and releases staged data.
        let receipt = ImportReceipt(filteredCount: 2, savedCount: 1, notSavedCount: 1, savedSites: [])
        #expect(model.sendImport(.finishSave(receipt, sessionID: sessionID)))
        #expect(model.importSession.staged == nil)
        #expect(model.importSession.phase == .receipt(receipt))

        // Closing drops staged data cleanly.
        model.sendImport(.addMorePasswords)
        let nextID = model.importSession.id
        model.stageIncomingBatch(makeBatch([known]), sessionID: nextID)
        #expect(model.importSession.staged != nil)
        #expect(model.sendImport(.closeFlow))
        #expect(model.importSession.phase == .closed)
        #expect(model.importSession.staged == nil)
    }

    @Test("MacVaultFileStore saves each import as a protobuf generation, keeps sealed copies that arrive before the first import, and removes old generations")
    func loginStoreGenerations() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ak-loginstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MacVaultFileStore(directory: dir)
        func generation(_ site: String, after previous: UUID?) -> StoredVaultSnapshot {
            StoredVaultSnapshot(id: UUID(), previousSnapshotID: previous, createdAt: .now, sourceExportedAt: .now, scope: .selected,
                             exporterIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords",
                             items: [makeItem(site: site)], skippedCredentialCount: 0)
        }
        var copy = Agentkeyring_V2_SealedLogin()
        copy.loginID = UUID().uuidString
        copy.openerID = "computer"

        // A computer joined before any copy from Passwords: its sealed copy is kept, with no import yet.
        try await store.replaceSealed([copy])
        #expect(try await store.loadCurrent() == nil)
        #expect(try await store.sealed() == [copy])

        let first = generation("github.com", after: nil)
        try await store.save(first) { $0 }
        #expect(try await store.loadCurrent()?.id == first.id)
        #expect(try await store.sealed() == [copy])
        let second = generation("openai.com", after: first.id)
        try await store.save(second, sealed: [])
        #expect(try await store.loadCurrent()?.items.first?.title == "openai.com")
        #expect(try await store.sealed().isEmpty)

        let pointer = try String(contentsOf: dir.appending(path: "current.generation"), encoding: .utf8)
        #expect(pointer.hasPrefix("pair:"))
        let token = String(pointer.dropFirst("pair:".count))
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(files == ["current.generation", "logins-\(token).pb", "sealed-\(token).pb"])
        #expect(try Data(contentsOf: dir.appending(path: "logins-\(token).pb")).starts(with: StoredVaultSnapshot.protobufMagic))

        // A list this build cannot decode starts the vault again.
        try Data("{}".utf8).write(to: dir.appending(path: "logins-\(token).pb"))
        #expect(try await store.loadCurrent() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }


    @Test("SelectiveImportSession Back clears waiting export state and ignores the abandoned export's timeout")
    @MainActor
    func selectiveImportBackCancelsExportTimeout() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ak-back-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "ak-back-timeout-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }

        let model = MacKeyringEngine(
            store: MacVaultFileStore(directory: folder.appending(path: "store")),
            accessControl: CredentialAccessController(store: LoginRuleStore(read: { nil }, write: { _ in })),
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases"))),
            settings: settings
        )
        model.enableBackgroundOnDeviceSorting = false
        var passwordsOpened = 0
        model.openApplePasswords = { _ in passwordsOpened += 1 }

        model.sendImport(.selectPath(.pickFew))
        #expect(model.sendImport(.continueFromChoose))
        model.openPasswordsExport()
        #expect(passwordsOpened == 1)

        #expect(model.importSession.exportState == .waiting)
        let attemptID = model.importSession.exportAttemptID

        #expect(model.sendImport(.backToChoose))
        #expect(model.importSession.step == .choose)
        #expect(model.importSession.exportState == .idle)
        // The abandoned export's timeout arriving late changes nothing.
        #expect(!model.sendImport(.exportTimedOut(attemptID: attemptID)))
        #expect(model.importSession.exportState == .idle)
    }
}
