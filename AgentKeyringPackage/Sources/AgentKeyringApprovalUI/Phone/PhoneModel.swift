// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// What the iPhone app shows and what it can ask for. Views read the model;
// everything real (iCloud, the relay, push, the Secure Enclave and Face ID)
// sits behind PhoneBackend.

import AgentKeyringApprovalCore
import Foundation
import Observation

@MainActor
@Observable
public final class PhoneModel {
    /// Single coupled state for an in-flight request answer so choice and request ID never desync.
    public struct ActiveAnswer: Equatable, Sendable {
        public let id: String
        public let choice: AnswerChoice
    }

    public struct RuleConfirmation: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let plan: RuleChangePlan<String>
        /// The logins whose rule changes, as listed.
        public let logins: [PhoneLogin]

        /// What changing the picked logins to `target` does; nil when nothing would change.
        public init?(_ target: LoginRule, picked: [PhoneLogin]) {
            let plan = RuleChangePlan(target: target, selected: picked.map(\.planned))
            guard !plan.isNoOp else { return nil }
            let affected = Set(plan.affectedLoginIDs)
            self.plan = plan
            self.logins = picked.filter { affected.contains($0.id) }
        }

        public var targetRule: LoginRule { plan.target }
    }

    public private(set) var snapshot: PhoneSnapshot
    public var tab = PhoneTab.home
    /// Selected login ID when pushed into Password Detail.
    public var detailLoginID: String?
    /// Pushes `PhoneCopyPasswordsPage(inFirstRun: false)` from Passwords tab.
    public var showCopyPasswords = false
    /// Plain-text category filter on Passwords (nil = All 10 categories).
    public var categoryFilter: String? = nil
    /// Explicit discoverable multi-select Edit Mode on iPhone Passwords.
    public var isEditingRules = false
    public var selectedForEdit: Set<String> = []
    public var ruleConfirmation: RuleConfirmation? = nil
    /// Single explicit state machine for every modal sheet, notification open, and per-request reply draft.
    public private(set) var sheet = PhoneSheetState()
    public private(set) var activeAnswer: ActiveAnswer?
    public var answering: AnswerChoice? { activeAnswer?.choice }
    /// The specific request ID currently authenticating or sending an answer.
    public var answeringID: String? { activeAnswer?.id }
    public private(set) var failure: String?
    /// In-flight guards for non-request actions so double taps never overlap Face ID or 30s retries.
    public private(set) var isAskingNotifications = false
    public private(set) var isAuthorizingWatch = false
    public private(set) var stoppingIDs: Set<String> = []
    public private(set) var isChangingRuleOrDevice = false
    public private(set) var isSyncing = false
    public private(set) var isResetting = false

    private let backend: any PhoneBackend
    /// Request ID whose notification notice is currently being decoded/refreshed.
    private var loadingNotificationID: String?
    /// Monotonic token invalidated whenever a newer explicit notification tap takes over.
    private var notificationToken: UInt64 = 0
    /// Explicit notification actions queued in FIFO order while another request is authenticating/sending
    /// so neither a Lock Screen Deny nor a second/third foreground tap is ever silently dropped.
    private var queuedNotifications: [(id: String, action: String, loadNotice: () async -> PhoneSnapshot?)] = []

    public func isLoadingNotification(_ id: String) -> Bool { loadingNotificationID == id }

    public init(backend: any PhoneBackend, initial: PhoneSnapshot) {
        self.backend = backend
        self.snapshot = initial
        if let practice = initial.practiceRequest {
            sheet.apply(.openDecide(id: practice.id))
        } else if initial.firstRun == .finished, initial.addWatch != nil {
            sheet.apply(.openAddWatch)
        }
    }

    public func followUpdates() async {
        for await next in backend.phoneSnapshotUpdates() {
            applySnapshot(next)
        }
    }

    /// Synchronizes `sheet` deterministically whenever the backend emits a new snapshot.
    /// Rejects stale snapshots whose revision is strictly older than the current snapshot.
    public func applySnapshot(_ next: PhoneSnapshot) {
        if next.revision > 0, next.revision < snapshot.revision { return }
        let previous = snapshot
        snapshot = next

        if let openID = sheet.requestID, openID != loadingNotificationID, openID != answeringID, sheet.requestMode != .settled {
            let current = accessRequest(id: openID)
            let stillPresentable = current.map { $0.state.isWaitingForYou || $0.state.isSending } ?? false
            if !stillPresentable {
                sheet.apply(.requestEnded(id: openID))
            } else if current?.state.isSending == true, sheet.requestMode != .approving {
                sheet.apply(.approveStarted(id: openID))
            }
        }

        if let practice = next.practiceRequest, previous.practiceRequest?.id != practice.id {
            // Never hijack an explicit notification that is loading or a request that is authenticating.
            if sheet.requestID != practice.id, answeringID == nil, loadingNotificationID == nil {
                sheet.apply(.openDecide(id: practice.id))
            }
        }

        if next.firstRun == .finished {
            if next.addWatch != nil, previous.addWatch == nil, answeringID == nil, loadingNotificationID == nil, sheet.presentation == .none {
                sheet.apply(.openAddWatch)
            } else if next.addWatch == nil, sheet.presentation == .addWatch {
                sheet.apply(.addWatchClosed)
            }
        } else if previous.firstRun == .finished {
            // Device was removed and returned to first run: close any lingering post-first-run sheet.
            if sheet.presentation == .settings || sheet.presentation == .addWatch {
                sheet.apply(.dismiss(expectedItem: sheet.item))
            }
        }
    }

    public var waiting: [AccessRequest] { snapshot.requests.filter(\.state.isWaitingForYou).sorted { $0.askedAt > $1.askedAt } }
    public var inUse: [AccessRequest] { snapshot.requests.filter(\.state.isInUse).sorted { $0.askedAt > $1.askedAt } }
    public var finished: [AccessRequest] {
        snapshot.requests.filter { !$0.state.isWaitingForYou && !$0.state.isInUse && !$0.state.isSending }
            .sorted { $0.askedAt > $1.askedAt }
    }

    public func accessRequest(id: String) -> AccessRequest? {
        snapshot.requests.first { $0.id == id }
            ?? (snapshot.practiceRequest?.id == id ? snapshot.practiceRequest : nil)
    }

    public func openDecide(_ id: String) {
        guard answeringID == nil else { return }
        let replacingAddWatch = sheet.presentation == .addWatch
        if snapshot.firstRun == .finished { tab = .home }
        notificationToken &+= 1
        loadingNotificationID = nil
        sheet.apply(.openDecide(id: id))
        if replacingAddWatch { Task { await backend.handleAddWatchTap(.cancel) } }
    }

    public func explain(_ id: String) {
        guard answeringID == nil else { return }
        let replacingAddWatch = sheet.presentation == .addWatch
        if snapshot.firstRun == .finished { tab = .home }
        notificationToken &+= 1
        loadingNotificationID = nil
        sheet.apply(.openExplain(id: id))
        if replacingAddWatch { Task { await backend.handleAddWatchTap(.cancel) } }
    }

    public func openSettled(_ id: String) {
        guard answeringID == nil else { return }
        sheet.apply(.openSettled(id: id))
    }

    public func approveForPreview(_ id: String) {
        sheet.apply(.approveStarted(id: id))
    }

    public func openSettings() {
        guard answeringID == nil, loadingNotificationID == nil else { return }
        let replacingAddWatch = sheet.presentation == .addWatch
        notificationToken &+= 1
        sheet.apply(.openSettings)
        if replacingAddWatch { Task { await backend.handleAddWatchTap(.cancel) } }
    }

    public func backToDecide() {
        guard answeringID == nil else { return }
        sheet.apply(.backToDecide)
    }

    public func draft(for id: String) -> String { sheet.draft(for: id) }

    public func setDraft(_ text: String, for id: String) {
        sheet.apply(.updateDraft(id: id, text: text))
    }

    public func dismissStaleNotice() {
        sheet.apply(.dismissStaleNotice)
    }

    /// Dismisses the active sheet cleanly (scoped to `expectedItem` so a stale SwiftUI dismiss callback
    /// from an older sheet can never dismiss a newer sheet).
    public func dismissSheet(expectedItem: PhoneSheetItem? = nil) {
        if let expectedItem, sheet.item != expectedItem { return }
        let openRequestID = sheet.requestID
        let wasAddWatch = (sheet.presentation == .addWatch)
        sheet.apply(.dismiss(expectedItem: expectedItem))
        if let openRequestID, openRequestID == snapshot.firstRun.practiceID || openRequestID == snapshot.practiceRequest?.id {
            Task { await sendFirstRunEvent(.practiceDismissed) }
        } else if wasAddWatch {
            Task { await handleAddWatchTap(.cancel) }
        }
        if !queuedNotifications.isEmpty, answeringID == nil, loadingNotificationID == nil {
            Task { @MainActor [weak self] in await self?.drainQueuedNotifications() }
        }
    }

    /// Single entry point for every notification tap or action from the Lock Screen or Notification Centre.
    /// Serializes against any in-flight authentication so an approval can never run behind another request
    /// and no explicit Lock Screen Deny or foreground tap is silently dropped.
    public func handleNotification(id: String, action: String, loadNotice: @escaping () async -> PhoneSnapshot?) async {
        // If any answer is currently in flight, keep the authenticating request on screen and enqueue
        // this explicit action in FIFO order (replacing any earlier queued intent for the same ID only).
        if answeringID != nil {
            if answeringID == id { return }
            enqueueNotification(id: id, action: action, loadNotice: loadNotice)
            return
        }

        if action == PhoneNotification.denyAction {
            if let refreshed = await loadNotice() { applySnapshot(refreshed) }
            if answeringID != nil {
                if answeringID != id { enqueueNotification(id: id, action: action, loadNotice: loadNotice) }
                return
            }
            guard let current = accessRequest(id: id), current.state.isWaitingForYou else { return }
            await answer(id, choice: .deny) { try await backend.denyAccessRequest(id, reply: nil) }
            return
        }

        let replacingAddWatch = sheet.presentation == .addWatch
        if snapshot.firstRun == .finished { tab = .home }

        notificationToken &+= 1
        let token = notificationToken
        loadingNotificationID = id

        // Set the single sheet state synchronously BEFORE awaiting `loadNotice` so any snapshot emitted
        // during `loadNotice` sees `sheet.requestID == id` and never overwrites the mode or bounces.
        switch action {
        case PhoneNotification.approveAction:
            sheet.apply(.notificationApproveTapped(id: id, isWaiting: true, endedNote: nil))
        case PhoneNotification.denyAndExplainAction:
            sheet.apply(.notificationExplainTapped(id: id, isWaiting: true, endedNote: nil))
        default:
            sheet.apply(.notificationTapped(id: id, isWaiting: true, endedNote: nil))
        }
        if replacingAddWatch { Task { await backend.handleAddWatchTap(.cancel) } }

        let refreshed = await loadNotice()
        // Keep `loadingNotificationID == id` during `applySnapshot` so a returned snapshot containing
        // practice or an ended state cannot hijack the sheet or skip setting `staleNotice`.
        if let refreshed { applySnapshot(refreshed) }
        if loadingNotificationID == id { loadingNotificationID = nil }

        // A newer explicit tap or sheet change took over while `loadNotice` was suspended: never act behind its back.
        guard token == notificationToken, sheet.requestID == id else { return }

        guard let current = accessRequest(id: id) else {
            sheet.apply(.notificationTapped(id: id, isWaiting: false, endedNote: PhoneCopy.staleRequestNote(.unanswered)))
            await drainQueuedNotifications()
            return
        }
        if current.state.isSending {
            sheet.apply(.notificationApproveTapped(id: id, isWaiting: true, endedNote: nil))
            return
        }
        if !current.state.isWaitingForYou {
            sheet.apply(.notificationTapped(id: id, isWaiting: false, endedNote: PhoneCopy.staleRequestNote(current.state)))
            await drainQueuedNotifications()
            return
        }

        if action == PhoneNotification.approveAction {
            await approveAccessRequest(id, reusingUnlock: true)
        } else {
            await drainQueuedBackgroundDenies()
        }
    }

    private func enqueueNotification(id: String, action: String, loadNotice: @escaping () async -> PhoneSnapshot?) {
        if let existing = queuedNotifications.firstIndex(where: { $0.id == id }) {
            queuedNotifications[existing] = (id: id, action: action, loadNotice: loadNotice)
        } else {
            queuedNotifications.append((id: id, action: action, loadNotice: loadNotice))
        }
    }

    /// Runs any queued background Lock Screen Denies right away without disturbing an open sheet.
    private func drainQueuedBackgroundDenies() async {
        while answeringID == nil,
              let index = queuedNotifications.firstIndex(where: { $0.action == PhoneNotification.denyAction }) {
            let next = queuedNotifications.remove(at: index)
            await handleNotification(id: next.id, action: next.action, loadNotice: next.loadNotice)
        }
    }

    /// Drains all queued background Denies first, then the next foreground notification if no sheet is open.
    private func drainQueuedNotifications() async {
        await drainQueuedBackgroundDenies()
        if answeringID == nil, loadingNotificationID == nil, sheet.presentation == .none, !queuedNotifications.isEmpty {
            let next = queuedNotifications.removeFirst()
            await handleNotification(id: next.id, action: next.action, loadNotice: next.loadNotice)
        }
    }

    public func approveAccessRequest(_ id: String, reusingUnlock: Bool = false) async {
        guard answeringID == nil else { return }
        sheet.apply(.approveStarted(id: id))
        await answer(id, choice: .approve) { try await backend.approveAccessRequest(id, reusingUnlock: reusingUnlock) }
    }

    public func denyAccessRequest(_ id: String, withDraft: Bool = true) async {
        guard answeringID == nil else { return }
        let reply = withDraft ? sheet.draft(for: id).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        await answer(id, choice: .deny) { try await backend.denyAccessRequest(id, reply: reply.isEmpty ? nil : reply) }
    }

    public func endApprovedAccess(_ id: String) async {
        guard !stoppingIDs.contains(id) else { return }
        stoppingIDs.insert(id)
        defer { stoppingIDs.remove(id) }
        do { try await backend.endApprovedAccess(id) } catch is PhoneStopNotConfirmed {
            failure = PhoneCopy.stopNotConfirmed
        } catch {
            var until: Date?
            if case let .approved(_, end)? = accessRequest(id: id)?.state { until = end }
            failure = PhoneCopy.stopFailed(until: until)
        }
    }

    /// Send Updates on Devices: the merged list signed and sent from this iPhone.
    public func sendUnsentChanges() async {
        guard !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do { try await backend.sendUnsentChanges() }
        catch is CancellationError {}
        catch { failure = PhoneCopy.changeFailed }
    }

    public func removeDevice(device id: String) async {
        guard !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do { try await backend.removeDevice(device: id) }
        catch is CancellationError {}
        catch { failure = PhoneCopy.changeFailed }
    }

    /// What iOS now allows, read again each time the app comes to the front: he may
    /// have turned notifications on in Settings, and first run then carries on by itself.
    public func recheckNotifications() async {
        guard !isAskingNotifications else { return }
        let status = await backend.checkNotifications()
        guard status.asked else { return }
        await backend.sendFirstRunEvent(.notificationsAnswered(allowed: status.facts.allowed))
    }

    /// iOS's own question, raised by Continue on the screen that says why.
    public func askAboutNotifications() async {
        guard snapshot.firstRun == .notifications, !isAskingNotifications else { return }
        isAskingNotifications = true
        defer { isAskingNotifications = false }
        await backend.sendFirstRunEvent(.continueTapped)
        let allowed = await backend.askForNotifications()
        await backend.sendFirstRunEvent(.notificationsAnswered(allowed: allowed))
    }

    public func sendFirstRunEvent(_ event: PhoneFirstRunEvent) async {
        await backend.sendFirstRunEvent(event)
        if snapshot.firstRun == .finished { tab = .home }
    }

    public func sendPracticeRequest(to deviceID: String? = nil) async {
        if let waiting = await backend.sendPracticeRequest(to: deviceID) { openDecide(waiting) }
    }
    public func savePhoneSettings(_ settings: PhoneSettings) async { await backend.savePhoneSettings(settings) }

    public func handleAddWatchTap(_ tap: PhoneAddWatchTap) async {
        if tap == .continueWithFaceID {
            guard !isAuthorizingWatch else { return }
            isAuthorizingWatch = true
            defer { isAuthorizingWatch = false }
            await backend.handleAddWatchTap(tap)
            return
        }
        await backend.handleAddWatchTap(tap)
        if tap == .open, snapshot.firstRun == .finished, snapshot.addWatch != nil,
           sheet.presentation == .none, answeringID == nil, loadingNotificationID == nil {
            sheet.apply(.openAddWatch)
        }
    }

    public func dismissFailure() { failure = nil }

    /// Set Up on This iPhone: Face ID, then this iPhone keeps the passwords itself.
    public func setUpHere() async {
        guard !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do { try await backend.setUpHere() }
        catch is CancellationError {}
        catch let failure as PhoneSetUpFailure { self.failure = failure.sentence }
        catch { failure = PhoneCopy.setUpFailed }
    }

    /// `asking`: iOS asks him to turn it on; otherwise it is only read.
    public func turnOnInPasswords(asking: Bool = true) async -> Bool { await backend.turnOnInPasswords(asking: asking) }
    public func handleAddComputerTap(_ tap: PhoneAddComputerTap) async { await backend.handleAddComputerTap(tap) }

    /// Add or Don't Add, for a Mac or iPhone asking to join through iCloud.
    public func answerDeviceJoin(add: Bool) async {
        guard !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do { try await backend.answerDeviceJoin(add: add) }
        catch is CancellationError {}
        catch { failure = PhoneCopy.addDeviceFailed }
    }

    public func syncWithICloudNow() async {
        guard !isSyncing, !isResetting else { return }
        isSyncing = true
        defer { isSyncing = false }
        await backend.syncWithICloudNow()
    }

    public func resetKeyring(includingICloud: Bool) async {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        do {
            try await backend.resetKeyring(includingICloud: includingICloud)
            if sheet.presentation == .settings || sheet.presentation == .addWatch {
                sheet.apply(.dismiss(expectedItem: sheet.item))
            }
        } catch is CancellationError {
        } catch {
            if sheet.presentation == .settings {
                sheet.apply(.dismiss(expectedItem: sheet.item))
            }
            failure = PhoneCopy.resetFailed
        }
    }

    private func answer(_ id: String, choice: AnswerChoice, send: () async throws -> Void) async {
        guard activeAnswer == nil else { return }
        activeAnswer = ActiveAnswer(id: id, choice: choice)
        var ended = false
        do {
            try await send()
            ended = true
            sheet.apply(.requestEnded(id: id))
        } catch is CancellationError {
            // Face ID cancelled: if we entered in Approving mode, drop cleanly to Decide.
            if choice == .approve { sheet.apply(.approveCancelled(id: id)) }
        } catch {
            if choice == .approve { sheet.apply(.approveCancelled(id: id)) }
            failure = PhoneCopy.answerFailed
        }
        activeAnswer = nil
        if !ended, let openID = sheet.requestID {
            let current = accessRequest(id: openID)
            let stillPresentable = current.map { $0.state.isWaitingForYou || $0.state.isSending } ?? false
            if !stillPresentable {
                sheet.apply(.requestEnded(id: openID))
            }
        }
        await drainQueuedNotifications()
    }
}

// MARK: - Passwords rule editing (multi-select Edit Mode and one password's rule)

extension PhoneModel {
    public func beginEditingRules() {
        isEditingRules = true
        selectedForEdit.removeAll()
        ruleConfirmation = nil
    }

    public func endEditingRules() {
        isEditingRules = false
        selectedForEdit.removeAll()
        ruleConfirmation = nil
    }

    public func toggleEditSelection(_ id: String) {
        if selectedForEdit.contains(id) {
            selectedForEdit.remove(id)
        } else {
            selectedForEdit.insert(id)
        }
    }

    public func requestRuleChange(_ rule: LoginRule) {
        guard let confirmation = RuleConfirmation(rule, picked: snapshot.logins.filter { selectedForEdit.contains($0.id) }) else {
            selectedForEdit.removeAll()
            return
        }
        ruleConfirmation = confirmation
    }

    public func cancelRuleChange() {
        ruleConfirmation = nil
    }

    public func confirmRuleChange() async {
        guard let confirmation = ruleConfirmation, !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do {
            try await backend.setLoginRule(confirmation.targetRule, forLogins: confirmation.plan.affectedLoginIDs)
            ruleConfirmation = nil
            selectedForEdit.removeAll()
            isEditingRules = false
        } catch is CancellationError {
        } catch {
            failure = PhoneCopy.changeFailed
        }
    }

    public func setLoginRule(_ rule: LoginRule, forLogin id: String) async {
        guard !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do { try await backend.setLoginRule(rule, forLogin: id) }
        catch is CancellationError {}
        catch { failure = PhoneCopy.changeFailed }
    }
}

extension AccessRequestState {
    var isSending: Bool {
        if case .sendingAnswer = self { return true }
        return false
    }
}
