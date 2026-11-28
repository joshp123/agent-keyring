// Written by AI on 2026.11.18 by model claude opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// The main Mac window's model: destination, filters, Edit Mode and every action it sends to the backend.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import Foundation
import Observation

public enum MacMainWindowTab: Hashable, Sendable { case logins, devices, activity }

public enum MacMainWindowDestination: Hashable, Sendable {
    case activity
    case passwords
    case devices
}

@MainActor
@Observable
public final class MacMainModel {

    public struct RuleConfirmation: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let plan: RuleChangePlan<UUID>
        /// The logins whose rule changes, as listed.
        public let logins: [LoginRow]

        /// What changing the picked logins to `target` does; nil when nothing would change.
        public init?(_ target: LoginRule, picked: [LoginRow]) {
            let plan = RuleChangePlan(target: target, selected: picked.map(\.planned))
            guard !plan.isNoOp else { return nil }
            let affected = Set(plan.affectedLoginIDs)
            self.plan = plan
            self.logins = picked.filter { affected.contains($0.id) }
        }

        public var targetRule: LoginRule { plan.target }
    }

    public enum WorkState: Equatable, Sendable {
        case idle
        case savingRules
        case updatingDevice
        case resetting
        case answeringRequest(String)
    }

    public enum DeviceDialog: Equatable, Sendable {
        case rename(id: String, name: String)
        case remove(id: String, name: String, isComputer: Bool)
        case reset
    }

    public var destination: MacMainWindowDestination = .passwords {
        didSet {
            if destination != .passwords {
                endEditingRules()
            }
        }
    }

    public var tab: MacMainWindowTab {
        get {
            switch destination {
            case .activity: .activity
            case .passwords: .logins
            case .devices: .devices
            }
        }
        set {
            switch newValue {
            case .activity: destination = .activity
            case .logins: destination = .passwords
            case .devices: destination = .devices
            }
        }
    }

    /// Composable Passwords filters (both axes work together; changing filters clears hidden selection).
    public var ruleFilter: LoginRule? = nil {
        didSet { if oldValue != ruleFilter { selectedForEdit.removeAll() } }
    }
    public var categoryFilter: ImportCategory? = nil {
        didSet { if oldValue != categoryFilter { selectedForEdit.removeAll() } }
    }

    public private(set) var snapshot: MainSnapshot
    public var search = "" {
        didSet { if oldValue != search { selectedForEdit.removeAll() } }
    }
    public var activitySearch = ""
    public var sortOrder = [KeyPathComparator(\LoginRow.asked, order: .reverse)]

    /// Explicit discoverable multi-select Edit Mode on Passwords (no staging bar).
    public var isEditingRules = false
    public var selectedForEdit: Set<UUID> = []
    public var ruleConfirmation: RuleConfirmation? = nil
    public private(set) var workState: WorkState = .idle
    public var isWorking: Bool { workState != .idle }
    public private(set) var failure: String?
    public var deviceDialog: DeviceDialog?
    public var renameDraft = ""
    private let backend: any MainWindowBackend

    public init(backend: any MainWindowBackend, initial: MainSnapshot) {
        self.backend = backend
        self.snapshot = initial
    }

    public func followUpdates() async {
        for await next in backend.mainWindowSnapshotUpdates() {
            snapshot = next
            selectedForEdit = selectedForEdit.intersection(Set(next.logins.map(\.id)))
        }
    }

    // MARK: Activity

    public var waitingRequests: [AccessRequest] {
        snapshot.requests.filter(\.state.isWaitingForYou).sorted { $0.askedAt > $1.askedAt }
    }

    private func matchesActivityQuery(_ req: AccessRequest) -> Bool {
        let q = activitySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return req.login.site.lowercased().contains(q)
            || req.login.account.lowercased().contains(q)
            || req.agent.name.lowercased().contains(q)
            || req.agent.machine.lowercased().contains(q)
            || req.agentReason.lowercased().contains(q)
    }

    public var todayRequests: [AccessRequest] {
        snapshot.requests
            .filter { !$0.state.isWaitingForYou && Calendar.current.isDateInToday($0.askedAt) && matchesActivityQuery($0) }
            .sorted { $0.askedAt > $1.askedAt }
    }

    public var earlierRequests: [AccessRequest] {
        snapshot.requests
            .filter { !$0.state.isWaitingForYou && !Calendar.current.isDateInToday($0.askedAt) && matchesActivityQuery($0) }
            .sorted { $0.askedAt > $1.askedAt }
    }

    public var recentRequests: [AccessRequest] { todayRequests }

    public var waitingCount: Int {
        waitingRequests.count + snapshot.enrolments.count
    }

    public var mascotMood: KeyringMascotMood {
        waitingCount > 0 ? .curious : .calm
    }

    // MARK: Passwords & Composable Filters

    public func loginCount(_ rule: LoginRule?) -> Int {
        guard let rule else { return snapshot.logins.count }
        return snapshot.logins.lazy.filter { $0.rule == rule }.count
    }

    public func categoryCount(_ category: ImportCategory) -> Int {
        snapshot.logins.lazy.filter { $0.category == category }.count
    }

    /// All 10 real buckets (8 everyday + Sensitive + Other), plain text + count (Option B).
    public var allCategories: [(id: ImportCategory, title: String, symbol: String, count: Int)] {
        MacImportCategoryOption.sidebarItems.map { item in
            (item.id, item.title, item.symbol, categoryCount(item.id))
        }
    }

    public var visibleLogins: [LoginRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return snapshot.logins.filter { row in
            let matchesRule = ruleFilter == nil || row.rule == ruleFilter
            let matchesCat = categoryFilter == nil || row.category == categoryFilter
            let matchesQuery = query.isEmpty
                || row.site.lowercased().contains(query)
                || row.account.lowercased().contains(query)
            return matchesRule && matchesCat && matchesQuery
        }
        .sorted(using: sortOrder)
    }

    // MARK: Discoverable Multi-Select Edit Mode

    public func beginEditingRules() {
        isEditingRules = true
        failure = nil
    }

    public func endEditingRules() {
        isEditingRules = false
        selectedForEdit.removeAll()
        ruleConfirmation = nil
    }

    public func toggleEditSelection(_ id: UUID) {
        if selectedForEdit.contains(id) {
            selectedForEdit.remove(id)
        } else {
            selectedForEdit.insert(id)
        }
    }

    public func clearEditSelection() {
        selectedForEdit.removeAll()
    }

    public func requestRuleChange(_ rule: LoginRule) {
        guard let confirmation = RuleConfirmation(rule, picked: snapshot.logins.filter { selectedForEdit.contains($0.id) }) else {
            selectedForEdit.removeAll()
            return
        }
        ruleConfirmation = confirmation
    }

    public func cancelRuleChange() {
        if workState == .savingRules { backend.cancelAuthentication() }
        ruleConfirmation = nil
        failure = nil
    }

    public func confirmRuleChange() {
        guard let confirmation = ruleConfirmation else { return }
        let changes = Dictionary(uniqueKeysWithValues: confirmation.logins.map { ($0.id, confirmation.targetRule) })
        run(.savingRules) { [backend] in
            try await backend.saveLoginRules(changes)
        } done: {
            self.ruleConfirmation = nil
            self.selectedForEdit.removeAll()
            self.isEditingRules = false
        }
    }

    // MARK: Activity Actions

    public func approveAccessRequest(_ id: String) {
        guard workState == .idle else { return }
        workState = .answeringRequest(id)
        failure = nil
        Task {
            defer { workState = .idle }
            do { try await backend.approveAccessRequest(id: id) }
            catch is CancellationError {}
            catch { failure = ownerAuthenticationFailure(error, fallback: MainWindowCopy.didNotFinish) }
        }
    }

    public func denyAccessRequest(_ id: String, reply: String?) {
        guard workState == .idle else { return }
        workState = .answeringRequest(id)
        failure = nil
        Task {
            defer { workState = .idle }
            do { try await backend.denyAccessRequest(id: id, reply: reply) }
            catch is CancellationError {}
            catch { failure = MainWindowCopy.didNotFinish }
        }
    }

    public func approveEnrolment(_ id: String) {
        guard workState == .idle else { return }
        workState = .answeringRequest(id)
        failure = nil
        Task {
            defer { workState = .idle }
            do { try await backend.approveEnrolment(id: id) }
            catch is CancellationError {}
            catch { failure = ownerAuthenticationFailure(error, fallback: MainWindowCopy.didNotFinish) }
        }
    }

    public func denyEnrolment(_ id: String) {
        guard workState == .idle else { return }
        workState = .answeringRequest(id)
        failure = nil
        Task {
            defer { workState = .idle }
            do { try await backend.denyEnrolment(id: id) }
            catch is CancellationError {}
            catch { failure = MainWindowCopy.didNotFinish }
        }
    }

    public func sendPracticeRequest(_ id: String) { backend.sendPracticeRequest(deviceID: id) }
    public func sendUnsentChanges() {
        guard workState == .idle else { return }
        workState = .updatingDevice
        failure = nil
        Task {
            defer { workState = .idle }
            do { try await backend.sendUnsentChanges() }
            catch is CancellationError {}
            catch { failure = ownerAuthenticationFailure(error, fallback: MainWindowCopy.didNotFinish) }
        }
    }
    public func syncWithICloudNow() { backend.syncWithICloudNow() }

    public func askToReset() {
        guard !isWorking else { return }
        deviceDialog = .reset
    }

    public func resetKeyring(includingICloud: Bool) {
        guard !isWorking else { return }
        deviceDialog = nil
        workState = .resetting
        failure = nil
        Task {
            defer { workState = .idle }
            do { try await backend.resetKeyring(includingICloud: includingICloud) }
            catch is CancellationError {}
            catch { failure = MainWindowCopy.resetFailed }
        }
    }

    public func setPasswordCopyReminder(_ on: Bool) { backend.setPasswordCopyReminder(on) }
    public func setOpensAtLogin(_ on: Bool) { backend.setOpensAtLogin(on) }
    public func setAnonymousTelemetry(_ on: Bool) { backend.setAnonymousTelemetry(on) }

    public func askToRemove(_ id: String, name: String, isComputer: Bool) {
        guard !isWorking else { return }
        deviceDialog = .remove(id: id, name: name, isComputer: isComputer)
    }

    public func removeDevice(_ id: String) {
        deviceDialog = nil
        run(.updatingDevice) { [backend] in try await backend.removeDevice(id: id) }
    }

    public func askToRename(_ id: String, name: String) {
        guard !isWorking else { return }
        renameDraft = name
        deviceDialog = .rename(id: id, name: name)
    }

    public func commitRename() {
        guard case let .rename(id, oldName) = deviceDialog else { return }
        let next = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceDialog = nil
        guard !next.isEmpty, next != oldName else { return }
        run(.updatingDevice) { [backend] in try await backend.renameDevice(id: id, to: next) }
    }

    public func dismissDeviceDialog() { deviceDialog = nil }
    public func importAgain() { backend.importAgain() }

    public func addManualPassword(website: String, account: String, password: String, totpSecret: String?, rule: LoginRule) async throws {
        try await backend.addManualPassword(website: website, account: account, password: password, totpSecret: totpSecret, rule: rule)
    }

    public func dismissFailure() { failure = nil }

    private func run(_ nextWork: WorkState, _ action: @escaping @MainActor () async throws -> Void, done: @escaping @MainActor () -> Void = {}) {
        guard workState == .idle else { return }
        workState = nextWork
        failure = nil
        Task {
            defer { workState = .idle }
            do {
                try await action()
                done()
            } catch is CancellationError {
            } catch {
                failure = ownerAuthenticationFailure(error, fallback: MainWindowCopy.didNotFinish)
            }
        }
    }
}
#endif
