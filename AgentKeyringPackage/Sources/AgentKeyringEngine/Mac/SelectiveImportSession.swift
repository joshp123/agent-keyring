// Written by AI on 2026.11.25 by model gemini-4-neon; refactored on 2026.11.26
// into an explicit session state machine so one value owns navigation, preset,
// per-row overrides and the in-memory staged batch; rewritten on 2026.11.27 by
// model claude opus 5.5 so every phase and event is named (StagedImport.swift
// holds the batch under review).
//
// Selective Apple Passwords import. Incoming exports stay in memory until the
// user clicks Save; Cancel drops them without writing to disk, keychain or iCloud.

#if os(macOS)
import AgentKeyringApprovalCore
import Foundation

public enum SelectiveImportEvent: Equatable, Sendable {
    // Opening, closing, and moving between the steps.
    case openFlow, closeFlow, reset, addMorePasswords, selectPath(ImportPath), continueFromChoose, setGuideStep(Int)
    case toggleCategory(ImportCategory), continueFromCategories, switchToAllPasswords, switchToCategories, switchToPickFew
    case backToChoose, backToCategories, openChangeCategories
    // The export from Passwords.
    case beginExportWaiting, exportTimedOut(attemptID: UUID), openAllowExport, closeAllowExport
    case beginImporting(sessionID: UUID), failExport(String?, sessionID: UUID), clearProblem
    // The batch under review.
    case stageIncoming(LoginImportBatch, sessionID: UUID), beginOnDeviceSorting(count: Int, sessionID: UUID)
    case applyOnDeviceCategory(ImportCategory, ids: [UUID], sessionID: UUID), finishOnDeviceSorting(sessionID: UUID)
    case toggleItem(UUID), includeAllSensitive, excludeAllSensitive
    // Saving.
    case beginSave, beginManualSave, finishSave(ImportReceipt, sessionID: UUID), finishManualSave(ImportReceipt?, sessionID: UUID)
    case failSave(sessionID: UUID), showManualReceipt(ImportReceipt)
}

public enum SelectiveImportExportState: Equatable, Sendable {
    case idle, waiting, noneArrived, allowExport, copying
}

/// Explicit state machine owning the selective-import session: one `Phase` enum
/// owns flow visibility, navigation, export progress, in-memory staged batch, and
/// saving state, plus a session token so late Apple transfers, export timeouts,
/// on-device classifications, or save completions can never race against Back,
/// Cancel, or a new session.
public struct SelectiveImportSession: Equatable, Sendable {
    public static let defaultCategories: Set<ImportCategory> = [.codingCloud, .aiTools]

    indirect public enum Phase: Equatable, Sendable {
        case closed
        case choose(staged: StagedImport? = nil)
        case pickFew(guideStep: Int, export: SelectiveImportExportState)
        case pickCategories(staged: StagedImport? = nil)
        case exportBridge(export: SelectiveImportExportState)
        case review(StagedImport)
        case saving(StagedImport)
        case manualSaving(previous: Phase)
        case receipt(ImportReceipt)

        public var isFlowOpen: Bool {
            switch self {
            case .closed: false
            case let .manualSaving(previous): previous.isFlowOpen
            case .choose, .pickFew, .pickCategories, .exportBridge, .review, .saving, .receipt: true
            }
        }

        public var step: SelectiveImportStep {
            switch self {
            case .closed, .choose: .choose
            case .pickFew: .pickFew
            case .pickCategories: .pickCategories
            case .exportBridge: .exportBridge
            case .review, .saving: .review
            case let .manualSaving(previous): previous.step
            case let .receipt(receipt): .receipt(receipt)
            }
        }

        public var exportState: SelectiveImportExportState {
            switch self {
            case let .pickFew(_, export): export
            case let .exportBridge(export): export
            case let .manualSaving(previous): previous.exportState
            case .closed, .choose, .pickCategories, .review, .saving, .receipt: .idle
            }
        }

        public var guideStep: Int {
            switch self {
            case let .pickFew(step, _): step
            case let .manualSaving(previous): previous.guideStep
            case .closed, .choose, .pickCategories, .exportBridge, .review, .saving, .receipt: 1
            }
        }

        public var staged: StagedImport? {
            switch self {
            case let .choose(staged), let .pickCategories(staged): staged
            case let .review(staged), let .saving(staged): staged
            case let .manualSaving(previous): previous.staged
            case .closed, .pickFew, .exportBridge, .receipt: nil
            }
        }

        public var isSaving: Bool {
            switch self {
            case .saving, .manualSaving: true
            case .closed, .choose, .pickFew, .pickCategories, .exportBridge, .review, .receipt: false
            }
        }
    }

    public private(set) var id: UUID
    public private(set) var phase: Phase
    public var path: ImportPath
    public var selectedCategories: Set<ImportCategory>
    public private(set) var exportAttemptID: UUID
    public var problem: String?

    public var isFlowOpen: Bool { phase.isFlowOpen }
    public var step: SelectiveImportStep { phase.step }
    public var exportState: SelectiveImportExportState { phase.exportState }
    public var guideStep: Int { phase.guideStep }
    public var staged: StagedImport? { phase.staged }
    public var isSaving: Bool { phase.isSaving }

    public init(id: UUID = UUID(), phase: Phase = .closed, path: ImportPath = .byCategory,
                selectedCategories: Set<ImportCategory> = Self.defaultCategories, exportAttemptID: UUID = UUID(), problem: String? = nil) {
        self.id = id
        self.phase = phase
        self.path = path
        self.selectedCategories = selectedCategories
        self.exportAttemptID = exportAttemptID
        self.problem = problem
    }

    private mutating func clearExportAttemptAndProblem() {
        exportAttemptID = UUID()
        problem = nil
    }

    /// Staged batch kept when navigating between Review, Choose, and Categories.
    /// Preserves `sortingRemainingCount` so switching to All Passwords while sorting never ticks unresolved rows.
    private var preservedStaged: StagedImport? {
        switch phase {
        case let .choose(staged), let .pickCategories(staged): staged
        case let .review(staged): staged
        case .closed, .pickFew, .exportBridge, .saving, .manualSaving, .receipt: nil
        }
    }

    /// Moves the session on. False if the event does not apply to where it is:
    /// a late answer from an earlier session or attempt, or anything but
    /// Cancel while saving. Every event is named here, and each helper names
    /// every phase, so a new event or phase does not compile until it is handled.
    @discardableResult
    public mutating func sendSelectiveImportEvent(_ event: SelectiveImportEvent) -> Bool {
        switch event {
        case .openFlow, .closeFlow, .reset:
            id = UUID()
            clearExportAttemptAndProblem()
            phase = event == .openFlow ? .choose(staged: nil) : .closed
            return true
        case .addMorePasswords:
            guard !isSaving else { return false }
            id = UUID()
            return move(to: .choose(staged: nil))
        case let .selectPath(newPath):
            guard !isSaving else { return false }
            path = newPath
            problem = nil
            return true
        case .continueFromChoose:
            guard !isSaving else { return false }
            switch path {
            case .pickFew: return move(to: .pickFew(guideStep: 1, export: .idle))
            case .byCategory: return move(to: .pickCategories(staged: preservedStaged))
            case .allPasswords: return reviewOrExport(path: .allPasswords) { $0.selectAllNonSensitive() }
            }
        case let .setGuideStep(nextStep):
            return setGuideStep(nextStep)
        case let .toggleCategory(category):
            return toggleCategory(category)
        case .continueFromCategories:
            guard !isSaving, !selectedCategories.isEmpty else { return false }
            let categories = selectedCategories
            return reviewOrExport(path: .byCategory) { $0.applyCategories(categories) }
        case .switchToAllPasswords:
            guard !isSaving else { return false }
            return reviewOrExport(path: .allPasswords) { $0.selectAllNonSensitive() }
        case .switchToCategories:
            guard !isSaving else { return false }
            path = .byCategory
            return move(to: .pickCategories(staged: preservedStaged))
        case .switchToPickFew:
            guard !isSaving else { return false }
            path = .pickFew
            return move(to: .pickFew(guideStep: 1, export: .idle))
        case .backToChoose:
            guard !isSaving else { return false }
            return move(to: .choose(staged: preservedStaged))
        case .backToCategories, .openChangeCategories:
            guard !isSaving else { return false }
            return move(to: .pickCategories(staged: preservedStaged))
        case .beginExportWaiting, .exportTimedOut, .openAllowExport, .closeAllowExport, .beginImporting, .failExport:
            return sendExport(event)
        case .clearProblem:
            problem = nil
            return true
        case let .stageIncoming(batch, sessionID):
            guard sessionID == id, !isSaving else { return false }
            return move(to: .review(StagedImport(batch: batch, path: path, selectedCategories: selectedCategories)))
        case let .beginOnDeviceSorting(count, sessionID):
            return updateReview(sessionID: sessionID) { $0.sortingRemainingCount = max(0, count) }
        case let .applyOnDeviceCategory(category, ids, sessionID):
            return updateReview(sessionID: sessionID) { $0.applyOnDeviceCategory(category, for: ids) }
        case let .finishOnDeviceSorting(sessionID):
            return updateReview(sessionID: sessionID) { $0.sortingRemainingCount = 0 }
        case let .toggleItem(itemID):
            return updateReview { $0.toggle(itemID) }
        case .includeAllSensitive:
            return updateReview { $0.includeAllSensitive() }
        case .excludeAllSensitive:
            return updateReview { $0.excludeAllSensitive() }
        case .beginSave, .beginManualSave, .finishSave, .finishManualSave, .failSave, .showManualReceipt:
            return sendSave(event)
        }
    }

    /// Goes to `next` with a new export attempt and no problem shown.
    private mutating func move(to next: Phase) -> Bool {
        clearExportAttemptAndProblem()
        phase = next
        return true
    }

    /// Reviews the batch already exported, changed by `apply`, instead of
    /// asking Passwords for a second export; with none yet, the export bridge.
    private mutating func reviewOrExport(path newPath: ImportPath, _ apply: (inout StagedImport) -> Void) -> Bool {
        path = newPath
        guard var existing = preservedStaged else { return move(to: .exportBridge(export: .idle)) }
        apply(&existing)
        return move(to: .review(existing))
    }

    private mutating func setGuideStep(_ nextStep: Int) -> Bool {
        switch phase {
        case let .pickFew(_, export):
            phase = .pickFew(guideStep: min(max(nextStep, 1), 5), export: export)
            return true
        case .closed, .choose, .pickCategories, .exportBridge, .review, .saving, .manualSaving, .receipt: return false
        }
    }

    /// Live category toggling on the Review screen also updates the staged batch in memory.
    private mutating func toggleCategory(_ category: ImportCategory) -> Bool {
        guard !isSaving, category != .sensitive, category != .other else { return false }
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
        let categories = selectedCategories
        if updateReview({ $0.applyCategories(categories) }) { path = .byCategory }
        return true
    }

    /// Changes the batch under review. With a session ID, only for this session.
    private mutating func updateReview(sessionID: UUID? = nil, _ change: (inout StagedImport) -> Void) -> Bool {
        if let sessionID, sessionID != id { return false }
        switch phase {
        case var .review(staged):
            change(&staged)
            phase = .review(staged)
            return true
        case .closed, .choose, .pickFew, .pickCategories, .exportBridge, .saving, .manualSaving, .receipt: return false
        }
    }

    /// Moves the export on the Pick a Few guide or the export bridge. Nil from `change` leaves it as it is.
    private mutating func changeExport(_ change: (SelectiveImportExportState) -> SelectiveImportExportState?) -> Bool {
        switch phase {
        case let .pickFew(step, export):
            guard let next = change(export) else { return false }
            phase = .pickFew(guideStep: step, export: next)
            return true
        case let .exportBridge(export):
            guard let next = change(export) else { return false }
            phase = .exportBridge(export: next)
            return true
        case .closed, .choose, .pickCategories, .review, .saving, .manualSaving, .receipt: return false
        }
    }

    /// The export from Passwords: waiting for it, its timeout, the Allow Export
    /// help, the transfer starting and failing. A timeout counts only for the
    /// attempt it was set for; a transfer only for this session.
    private mutating func sendExport(_ event: SelectiveImportEvent) -> Bool {
        switch event {
        case .beginExportWaiting:
            guard !isSaving, changeExport({ _ in .waiting }) else { return false }
            clearExportAttemptAndProblem()
            return true
        case let .exportTimedOut(attemptID):
            guard attemptID == exportAttemptID else { return false }
            return changeExport { export in
                switch export {
                case .waiting: .noneArrived
                case .idle, .noneArrived, .allowExport, .copying: nil
                }
            }
        case .openAllowExport:
            guard !isSaving, changeExport({ _ in .allowExport }) else { return false }
            exportAttemptID = UUID()
            return true
        case .closeAllowExport:
            let closed = changeExport { export in
                switch export {
                case .allowExport: .idle
                case .idle, .waiting, .noneArrived, .copying: nil
                }
            }
            guard closed else { return false }
            exportAttemptID = UUID()
            return true
        case let .beginImporting(sessionID):
            guard sessionID == id else { return false }
            switch phase {
            case let .pickFew(step, _): phase = .pickFew(guideStep: step, export: .copying)
            case .exportBridge, .closed, .choose, .pickCategories, .receipt: phase = .exportBridge(export: .copying)
            case .review, .saving, .manualSaving: return false
            }
            clearExportAttemptAndProblem()
            return true
        case let .failExport(message, sessionID):
            guard sessionID == id else { return false }
            _ = changeExport { export in
                switch export {
                case .copying: .idle
                case .idle, .waiting, .noneArrived, .allowExport: nil
                }
            }
            exportAttemptID = UUID()
            problem = message
            return true
        case .openFlow, .closeFlow, .reset, .addMorePasswords, .selectPath, .continueFromChoose, .setGuideStep, .toggleCategory,
             .continueFromCategories, .switchToAllPasswords, .switchToCategories, .switchToPickFew, .backToChoose, .backToCategories,
             .openChangeCategories, .clearProblem, .stageIncoming, .beginOnDeviceSorting, .applyOnDeviceCategory,
             .finishOnDeviceSorting, .toggleItem, .includeAllSensitive, .excludeAllSensitive, .beginSave, .beginManualSave,
             .finishSave, .finishManualSave, .failSave, .showManualReceipt:
            return false
        }
    }

    /// Saving the reviewed batch, or a password he added by hand. A finish or
    /// failure counts only for this session.
    private mutating func sendSave(_ event: SelectiveImportEvent) -> Bool {
        switch event {
        case .beginSave:
            switch phase {
            case let .review(staged):
                guard staged.selectedCount > 0 else { return false }
                phase = .saving(staged)
                return true
            case .closed, .choose, .pickFew, .pickCategories, .exportBridge, .saving, .manualSaving, .receipt: return false
            }
        case .beginManualSave:
            guard !isSaving else { return false }
            phase = .manualSaving(previous: phase)
            return true
        case let .finishSave(receipt, sessionID):
            guard sessionID == id else { return false }
            switch phase {
            case .saving: return move(to: .receipt(receipt))
            case .closed, .choose, .pickFew, .pickCategories, .exportBridge, .review, .manualSaving, .receipt: return false
            }
        case let .finishManualSave(receipt, sessionID):
            guard sessionID == id else { return false }
            switch phase {
            case let .manualSaving(previous): return move(to: receipt.map(Phase.receipt) ?? previous)
            case .closed, .choose, .pickFew, .pickCategories, .exportBridge, .review, .saving, .receipt: return false
            }
        case let .failSave(sessionID):
            guard sessionID == id else { return false }
            switch phase {
            case let .saving(staged): phase = .review(staged)
            case let .manualSaving(previous): phase = previous
            case .closed, .choose, .pickFew, .pickCategories, .exportBridge, .review, .receipt: return false
            }
            return true
        case let .showManualReceipt(receipt):
            guard !isSaving else { return false }
            return move(to: .receipt(receipt))
        case .openFlow, .closeFlow, .selectPath, .continueFromChoose, .setGuideStep, .toggleCategory, .continueFromCategories,
             .switchToAllPasswords, .switchToCategories, .switchToPickFew, .backToChoose, .backToCategories,
             .openChangeCategories, .beginExportWaiting, .exportTimedOut, .openAllowExport, .closeAllowExport,
             .beginImporting, .failExport, .clearProblem, .stageIncoming, .beginOnDeviceSorting, .applyOnDeviceCategory,
             .finishOnDeviceSorting, .toggleItem, .includeAllSensitive, .excludeAllSensitive, .addMorePasswords, .reset:
            return false
        }
    }
}
#endif
