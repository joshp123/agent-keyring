// Written by AI on 2026.11.25 by model gemini-4-neon; edited on 2026.11.27 by model claude opus 5.5.
//
// An Apple Passwords export held in memory during review: which rows are
// ticked, from the preset and his own edits, the receipt once saved, and the
// sub-step the window shows. Nothing here is written to disk, keychain or iCloud.

#if os(macOS)
import AgentKeyringApprovalCore
import Foundation

/// One exported password held in memory during review.
public struct StagedImportItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let item: StoredVaultLogin
    public let displayName: String
    public let host: String
    public let account: String
    /// Resolved category (from the 500k offline catalogue, deterministic rules,
    /// cache, or background Apple Intelligence). Nil while still unsorted.
    public var category: ImportCategory?

    public var isSensitive: Bool { category == .sensitive }

    public init(item: StoredVaultLogin) {
        self.id = item.id
        self.item = item
        self.displayName = DomainClassifier.displayName(origins: item.origins, title: item.title)
        self.host = DomainClassifier.primaryHost(origins: item.origins, title: item.title)
        self.account = item.accountName ?? item.subtitle ?? ""
        self.category = DomainClassifier.classify(item)
            ?? OnDeviceCategoryClassifier.shared.cachedCategory(for: item)
    }
}

/// One saved site shown on a receipt, carrying both its label and real host for icon lookup.
public struct SavedReceiptSite: Equatable, Hashable, Sendable {
    public let displayName: String
    public let host: String

    public init(displayName: String, host: String) {
        self.displayName = displayName
        self.host = host
    }
}

public enum StagedImportPreset: Equatable, Sendable {
    /// Small Pick-a-Few export: every received login starts ticked.
    case allReceived
    /// Bulk / All Passwords export: every non-sensitive login starts ticked; sensitive starts unticked.
    case allNonSensitive
    /// Category filter: non-sensitive logins in `categories` start ticked; everything else starts unticked.
    case categories(Set<ImportCategory>)
}

/// An incoming Apple Passwords export held strictly in memory until confirmed.
/// Derives checked rows from `preset` plus explicit per-row `overrides` so switching
/// between categories or All preserves manual edits without re-exporting.
public struct StagedImport: Equatable, Sendable {

    public let batch: LoginImportBatch
    public var preset: StagedImportPreset
    public var overrides: [UUID: Bool]
    public var items: [StagedImportItem]
    /// Number of unlisted items still being sorted on device by Apple Intelligence.
    public var sortingRemainingCount: Int = 0

    /// Threshold above which an accidental "Export All" on Path A applies
    /// sensitive default exclusion as an extra safety net.
    static let largeExportThreshold = 15

    public init(batch: LoginImportBatch, path: ImportPath, selectedCategories: Set<ImportCategory>) {
        self.batch = batch
        let staged = batch.items
            .filter { !$0.isTestPassword }
            .map(StagedImportItem.init)
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        self.items = staged
        self.preset = Self.initialPreset(itemCount: staged.count, path: path, categories: selectedCategories)
        self.overrides = [:]
        self.sortingRemainingCount = 0
    }

    /// Items absent from the 500k offline table and cache, eligible for on-device Apple Intelligence.
    public var unsortedItems: [StagedImportItem] {
        items.filter { $0.category == nil }
    }

    public var path: ImportPath {
        switch preset {
        case .categories: .byCategory
        case .allNonSensitive: .allPasswords
        case .allReceived: .pickFew
        }
    }

    public var selectedCategories: Set<ImportCategory> {
        if case let .categories(cats) = preset { return cats }
        return []
    }

    func defaultSelection(for item: StagedImportItem) -> Bool {
        switch preset {
        case .allReceived:
            return true
        case .allNonSensitive:
            if item.category == nil, sortingRemainingCount > 0 { return false }
            return !item.isSensitive
        case let .categories(cats):
            guard let category = item.category, category != .sensitive, category != .other else { return false }
            return cats.contains(category)
        }
    }

    public func isSelected(_ item: StagedImportItem) -> Bool {
        overrides[item.id] ?? defaultSelection(for: item)
    }

    public var selectedIDs: Set<UUID> {
        Set(items.filter { isSelected($0) }.map(\.id))
    }

    public var totalCount: Int { items.count }
    public var selectedCount: Int { items.reduce(0) { $0 + (isSelected($1) ? 1 : 0) } }
    public var excludedCount: Int { max(items.count - selectedCount, 0) }

    /// Unchecked non-sensitive logins (outside chosen categories or manually unticked).
    public var otherExcludedItems: [StagedImportItem] {
        items.filter { !$0.isSensitive && !isSelected($0) }
    }

    /// Unchecked sensitive logins (banking, crypto, government, password managers).
    public var excludedSensitiveItems: [StagedImportItem] {
        items.filter { $0.isSensitive && !isSelected($0) }
    }

    /// All sensitive logins in this batch, whether currently ticked or unticked.
    var allSensitiveItems: [StagedImportItem] {
        items.filter(\.isSensitive)
    }

    /// Deduplicated display names for the sensitive summary (e.g. "1Password (2)" instead of "1Password, 1Password").
    public var groupedExcludedSensitiveNames: [String] {
        Self.groupedSiteNames(excludedSensitiveItems)
    }

    static func groupedSiteNames(_ items: [StagedImportItem]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for item in items {
            let key = item.displayName.lowercased()
            if counts[key] == nil {
                order.append(item.displayName)
            }
            counts[key, default: 0] += 1
        }
        return order.map { name in
            let count = counts[name.lowercased()] ?? 1
            return count > 1 ? "\(name) (\(count))" : name
        }
    }

    /// Counts of non-sensitive logins per selectable category in this batch.
    public func loginCount(in category: ImportCategory) -> Int {
        items.reduce(0) { $0 + ($1.category == category ? 1 : 0) }
    }

    public var selectedVaultLogins: [StoredVaultLogin] {
        items.filter { isSelected($0) }.map(\.item)
    }

    var selectedBatch: LoginImportBatch {
        LoginImportBatch(
            scope: .selected,
            exportedAt: batch.exportedAt,
            exporterIdentifier: batch.exporterIdentifier,
            exporterDisplayName: batch.exporterDisplayName,
            items: selectedVaultLogins,
            skippedCredentialCount: batch.skippedCredentialCount,
            skippedCredentialSummary: batch.skippedCredentialSummary
        )
    }

    public mutating func toggle(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let next = !isSelected(item)
        if next == defaultSelection(for: item) {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = next
        }
    }

    public mutating func includeAllSensitive() {
        for item in items where item.isSensitive {
            if defaultSelection(for: item) {
                overrides.removeValue(forKey: item.id)
            } else {
                overrides[item.id] = true
            }
        }
    }

    public mutating func excludeAllSensitive() {
        for item in items where item.isSensitive {
            if !defaultSelection(for: item) {
                overrides.removeValue(forKey: item.id)
            } else {
                overrides[item.id] = false
            }
        }
    }

    /// Applies a new category set while preserving explicit manual row decisions.
    public mutating func applyCategories(_ categories: Set<ImportCategory>) {
        preset = .categories(categories)
    }

    /// Switches to All non-sensitive passwords in memory while preserving explicit manual row decisions.
    mutating func selectAllNonSensitive() {
        preset = .allNonSensitive
    }

    /// Applies an on-device Apple Intelligence category result to matching items.
    /// Manual per-row overrides are never overwritten, so user decisions always win.
    public mutating func applyOnDeviceCategory(_ category: ImportCategory, for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        var updated = 0
        for idx in items.indices where idSet.contains(items[idx].id) {
            if items[idx].category == nil {
                updated += 1
            }
            items[idx].category = category
        }
        if updated > 0 {
            sortingRemainingCount = max(0, sortingRemainingCount - updated)
        }
    }

    public func makeReceipt(committedIDs: Set<UUID>? = nil, isReimport: Bool = false) -> ImportReceipt {
        let kept = items.filter { item in
            guard isSelected(item) else { return false }
            if let committedIDs { return committedIDs.contains(item.id) }
            return true
        }
        return ImportReceipt(
            filteredCount: items.count,
            savedCount: kept.count,
            notSavedCount: max(items.count - kept.count, 0),
            savedSites: kept.map { SavedReceiptSite(displayName: $0.displayName, host: $0.host) },
            isReimport: isReimport
        )
    }

    private static func initialPreset(
        itemCount: Int,
        path: ImportPath,
        categories: Set<ImportCategory>
    ) -> StagedImportPreset {
        switch path {
        case .byCategory:
            return .categories(categories)
        case .allPasswords:
            return .allNonSensitive
        case .pickFew:
            return itemCount > largeExportThreshold ? .allNonSensitive : .allReceived
        }
    }
}

/// Summary shown after a selective import (or manual add) is saved.
public struct ImportReceipt: Equatable, Sendable {
    public let filteredCount: Int
    public let savedCount: Int
    public let notSavedCount: Int
    public let savedSites: [SavedReceiptSite]
    public let isReimport: Bool

    public init(
        filteredCount: Int,
        savedCount: Int,
        notSavedCount: Int,
        savedSites: [SavedReceiptSite],
        isReimport: Bool = false
    ) {
        self.filteredCount = filteredCount
        self.savedCount = savedCount
        self.notSavedCount = notSavedCount
        self.savedSites = savedSites
        self.isReimport = isReimport
    }
}

/// Sub-step inside "Add passwords" (Step 3 of 5, or Copy Again from the main window).
public enum SelectiveImportStep: Equatable, Sendable {
    case choose
    case pickFew
    case pickCategories
    case exportBridge
    case review
    case receipt(ImportReceipt)
}
#endif
