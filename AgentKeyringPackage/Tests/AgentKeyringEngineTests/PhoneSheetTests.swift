// Written by AI on 2026.11.21 by model Gemini 4 Neon.
//
// Explicit state machine and integration regression tests for PhoneSheetState,
// PhoneModel, and PhoneFirstRun, covering every concurrency and ordering edge case:
// - Normal notification tap -> Decide (never Explain/Deny)
// - Long-press Approve -> Approving (never Deny form, never double-sheet bounce)
// - Delayed out-of-order AsyncStream snapshot never dismisses Explain or reopens Decide
// - Suspended notification loader for A never approves A behind B
// - Practice snapshot arriving while notification B is loading never hijacks B's sheet
// - Tapping Lock Screen Deny or Approve on B/C while A is authenticating keeps A visible and runs queued actions FIFO
// - Disappearing request during cancelled/failed auth clears sheet cleanly (never leaves an undismissable spinner)
// - Practice Cancel followed by the 30-second timer never reopens the sheet, and Send Another / Try Again / Skip all work
// - Scoped sheet dismissal never dismisses a newer sheet
// - Settings sheet lives in the same single modal slot and yields cleanly to notification taps
// - Per-request draft isolation across concurrent notifications

import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import Foundation
import Testing

@MainActor
private final class ControlledPhoneBackend: PhoneBackend {
    var snapshot: PhoneSnapshot
    var approvedIDs: [String] = []
    var deniedIDs: [(String, String?)] = []
    var blockApproveForID: String?
    var failApproveForID: String?
    private var approveGate: CheckedContinuation<Void, Never>?
    private var gateEnteredWaiter: CheckedContinuation<Void, Never>?
    private var gateReached = false
    private var subscribers: [UUID: AsyncStream<PhoneSnapshot>.Continuation] = [:]

    init(initial: PhoneSnapshot) {
        self.snapshot = initial
    }

    func waitForApproveGate() async {
        if gateReached { return }
        await withCheckedContinuation { continuation in
            gateEnteredWaiter = continuation
        }
    }

    func releaseApproveGate() {
        gateReached = false
        approveGate?.resume()
        approveGate = nil
    }

    func phoneSnapshotUpdates() -> AsyncStream<PhoneSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers.removeValue(forKey: id) } }
        }
    }

    func emit(_ next: PhoneSnapshot) {
        snapshot = next
        for continuation in subscribers.values { continuation.yield(next) }
    }

    func approveAccessRequest(_ requestID: String, reusingUnlock: Bool) async throws {
        if blockApproveForID == requestID {
            await withCheckedContinuation { continuation in
                approveGate = continuation
                gateReached = true
                gateEnteredWaiter?.resume()
                gateEnteredWaiter = nil
            }
        }
        if failApproveForID == requestID {
            throw CancellationError()
        }
        approvedIDs.append(requestID)
        var next = snapshot
        next.revision &+= 1
        if let idx = next.requests.firstIndex(where: { $0.id == requestID }) {
            next.requests[idx].state = .approved(by: .iPhone, until: .now.addingTimeInterval(1800))
        }
        emit(next)
    }

    func denyAccessRequest(_ requestID: String, reply: String?) async throws {
        deniedIDs.append((requestID, reply))
        var next = snapshot
        next.revision &+= 1
        if let idx = next.requests.firstIndex(where: { $0.id == requestID }) {
            next.requests[idx].state = .denied(by: .iPhone, reply: reply, askAgainAfter: nil)
        }
        emit(next)
    }

    func endApprovedAccess(_ requestID: String) async throws {}
    func setLoginRule(_ rule: LoginRule, forLogin loginID: String) async throws { Issue.record("Unexpected setRule") }
    func removeDevice(device deviceID: String) async throws { Issue.record("Unexpected remove") }
    func sendFirstRunEvent(_ event: PhoneFirstRunEvent) async {
        var next = snapshot
        next.revision &+= 1
        next.firstRun = snapshot.firstRun.on(event)
        next.practiceRequest = next.firstRun == .practice(id: "practice") ? .practiceAccessRequest() : nil
        emit(next)
    }
    func checkNotifications() async -> PhoneNotificationStatus { PhoneNotificationStatus(asked: false, facts: PhoneNotificationFacts()) }
    func askForNotifications() async -> Bool { Issue.record("Unexpected askForNotifications"); return false }
    func sendPracticeRequest(to deviceID: String?) async -> String? { nil }
    func savePhoneSettings(_ settings: PhoneSettings) async {}
    func handleAddWatchTap(_ tap: PhoneAddWatchTap) async {}
    // Not reached by these tests.
    func setLoginRule(_ rule: LoginRule, forLogins loginIDs: [String]) async throws { Issue.record("Unexpected setRule") }
    func sendUnsentChanges() async throws { Issue.record("Unexpected sendUpdates") }
    func setUpHere() async throws { Issue.record("Unexpected setUpHere") }
    func turnOnInPasswords(asking: Bool) async -> Bool { Issue.record("Unexpected turnOnInPasswords"); return false }
    func handleAddComputerTap(_ tap: PhoneAddComputerTap) async { Issue.record("Unexpected addComputer") }
    func answerDeviceJoin(add: Bool) async throws { Issue.record("Unexpected answerDeviceJoin") }
    func syncWithICloudNow() async { Issue.record("Unexpected syncNow") }
    func resetKeyring(includingICloud: Bool) async throws { Issue.record("Unexpected reset") }
}

private func makeWaitingRequest(id: String, site: String = "example.com") -> AccessRequest {
    AccessRequest(
        id: id,
        login: RequestedLogin(site: site, account: "you@example.com"),
        agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: ""),
        access: .login,
        agentReason: "Checking status.",
        askedAt: .now,
        state: .waitingForYou(until: .now.addingTimeInterval(600))
    )
}

@Suite("iPhone sheet state machine")
struct PhoneSheetTests {
    @Test("Normal notification tap opens Decide, never Explain/Deny")
    func normalTapOpensDecide() {
        var state = PhoneSheetState()
        state.apply(.notificationTapped(id: "r1", isWaiting: true, endedNote: nil))
        #expect(state.presentation == .request(id: "r1", mode: .decide, canReturnToDecide: false))
        #expect(state.item == .request(id: "r1"))
    }

    @Test("Long-press Approve opens Approving (never Explain), and Face ID cancel returns cleanly to Decide")
    func approveActionOpensApprovingAndFallsBackOnCancel() {
        var state = PhoneSheetState()
        state.apply(.notificationApproveTapped(id: "r1", isWaiting: true, endedNote: nil))
        #expect(state.presentation == .request(id: "r1", mode: .approving, canReturnToDecide: false))
        #expect(state.item == .request(id: "r1"))

        state.apply(.approveCancelled(id: "r1"))
        #expect(state.presentation == .request(id: "r1", mode: .decide, canReturnToDecide: false))
        #expect(state.item == .request(id: "r1"))
    }

    @Test("Moving Decide -> Explain -> Back keeps the exact same sheet item identity (zero modal bounce)")
    func modeChangesStayInPlace() {
        var state = PhoneSheetState()
        state.apply(.openDecide(id: "r1"))
        let decideItem = state.item
        state.apply(.openExplain(id: "r1"))
        #expect(state.item == decideItem)
        #expect(state.presentation == .request(id: "r1", mode: .explain, canReturnToDecide: true))
        state.apply(.backToDecide)
        #expect(state.item == decideItem)
        #expect(state.presentation == .request(id: "r1", mode: .decide, canReturnToDecide: false))
    }

    @Test("Multiple notifications keep drafts isolated per request ID and never leak text across requests")
    func draftsStayIsolatedAcrossNotifications() {
        var state = PhoneSheetState()
        state.apply(.notificationExplainTapped(id: "r1", isWaiting: true, endedNote: nil))
        state.apply(.updateDraft(id: "r1", text: "Use the file in Downloads"))
        #expect(state.draft(for: "r1") == "Use the file in Downloads")

        state.apply(.notificationTapped(id: "r2", isWaiting: true, endedNote: nil))
        #expect(state.presentation == .request(id: "r2", mode: .decide, canReturnToDecide: false))
        #expect(state.draft(for: "r2").isEmpty)
        #expect(state.draft(for: "r1") == "Use the file in Downloads")

        state.apply(.requestEnded(id: "r1"))
        #expect(state.draft(for: "r1").isEmpty)
        #expect(state.presentation == .request(id: "r2", mode: .decide, canReturnToDecide: false))
    }

    @Test("Tapping a notification for an already-ended request shows a stale notice and opens no sheet")
    func staleNotificationSetsNoticeWithoutOpeningSheet() {
        var state = PhoneSheetState()
        state.apply(.notificationTapped(id: "r1", isWaiting: false, endedNote: "This request was already approved."))
        #expect(state.presentation == .none)
        #expect(state.staleNotice == "This request was already approved.")
        state.apply(.dismissStaleNotice)
        #expect(state.staleNotice == nil)
    }

    @MainActor
    @Test("Delayed older snapshot after opening Explain never dismisses Explain or reopens Decide")
    func delayedOlderSnapshotDoesNotDismissExplainOrReopenDecide() {
        var oldSnap = PhoneSnapshot(firstRun: .practiceWaiting(id: "practice", arrived: true))
        oldSnap.revision = 1
        var currentSnap = PhoneSnapshot(firstRun: .practice(id: "practice"), practiceRequest: .practiceAccessRequest())
        currentSnap.revision = 2

        let backend = ControlledPhoneBackend(initial: currentSnap)
        let model = PhoneModel(backend: backend, initial: currentSnap)

        model.explain("practice")
        #expect(model.sheet.presentation == .request(id: "practice", mode: .explain, canReturnToDecide: true))

        model.applySnapshot(oldSnap)
        #expect(model.sheet.presentation == .request(id: "practice", mode: .explain, canReturnToDecide: true))
        model.applySnapshot(currentSnap)
        #expect(model.sheet.presentation == .request(id: "practice", mode: .explain, canReturnToDecide: true))
    }

    @MainActor
    @Test("Suspended notification loader for A never approves A after user opens B")
    func suspendedLoaderANeverApprovesBehindB() async {
        var snap = PhoneSnapshot(firstRun: .finished, requests: [makeWaitingRequest(id: "rA"), makeWaitingRequest(id: "rB")])
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        let model = PhoneModel(backend: backend, initial: snap)

        var resumeA: CheckedContinuation<PhoneSnapshot?, Never>?
        var loaderEntered = false
        var loaderWaiter: CheckedContinuation<Void, Never>?

        let taskA = Task { @MainActor in
            await model.handleNotification(id: "rA", action: PhoneNotification.approveAction) {
                await withCheckedContinuation { continuation in
                    resumeA = continuation
                    loaderEntered = true
                    loaderWaiter?.resume()
                    loaderWaiter = nil
                }
            }
        }
        if !loaderEntered {
            await withCheckedContinuation { continuation in loaderWaiter = continuation }
        }
        #expect(model.sheet.presentation == .request(id: "rA", mode: .approving, canReturnToDecide: false))

        model.openDecide("rB")
        #expect(model.sheet.presentation == .request(id: "rB", mode: .decide, canReturnToDecide: false))

        resumeA?.resume(returning: backend.snapshot)
        await taskA.value

        #expect(backend.approvedIDs.isEmpty)
        #expect(model.sheet.presentation == .request(id: "rB", mode: .decide, canReturnToDecide: false))
    }

    @MainActor
    @Test("Practice snapshot arriving while notification B is loading never hijacks B's sheet")
    func practiceSnapshotNeverHijacksLoadingNotification() async {
        var snap = PhoneSnapshot(firstRun: .practiceWaiting(id: "practice", arrived: true), requests: [makeWaitingRequest(id: "rB")])
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        let model = PhoneModel(backend: backend, initial: snap)

        var resumeB: CheckedContinuation<PhoneSnapshot?, Never>?
        var loaderEntered = false
        var loaderWaiter: CheckedContinuation<Void, Never>?

        let taskB = Task { @MainActor in
            await model.handleNotification(id: "rB", action: PhoneNotification.approveAction) {
                await withCheckedContinuation { continuation in
                    resumeB = continuation
                    loaderEntered = true
                    loaderWaiter?.resume()
                    loaderWaiter = nil
                }
            }
        }
        if !loaderEntered {
            await withCheckedContinuation { continuation in loaderWaiter = continuation }
        }

        // A snapshot opening practice arrives while B's loader is suspended:
        var practiceSnap = snap
        practiceSnap.revision = 2
        practiceSnap.firstRun = .practice(id: "practice")
        practiceSnap.practiceRequest = .practiceAccessRequest()
        model.applySnapshot(practiceSnap)

        // B MUST keep sheet ownership; practice MUST NOT hijack B!
        #expect(model.sheet.requestID == "rB")

        resumeB?.resume(returning: practiceSnap)
        await taskB.value
        #expect(backend.approvedIDs == ["rB"])
    }

    @MainActor
    @Test("Lock Screen Deny and foreground Approve taps queued while A authenticates all execute FIFO without drops")
    func queuedDenyAndApproveRunFIFOAfterActiveApproval() async {
        var snap = PhoneSnapshot(
            firstRun: .finished,
            requests: [makeWaitingRequest(id: "rA"), makeWaitingRequest(id: "rB"), makeWaitingRequest(id: "rC")]
        )
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        backend.blockApproveForID = "rA"
        let model = PhoneModel(backend: backend, initial: snap)

        let taskA = Task { @MainActor in
            await model.handleNotification(id: "rA", action: PhoneNotification.approveAction) { backend.snapshot }
        }
        await backend.waitForApproveGate()
        #expect(model.answeringID == "rA")
        #expect(model.sheet.presentation == .request(id: "rA", mode: .approving, canReturnToDecide: false))

        // While A is authenticating, user taps Lock Screen Deny on B AND Approve on C:
        await model.handleNotification(id: "rB", action: PhoneNotification.denyAction) { backend.snapshot }
        await model.handleNotification(id: "rC", action: PhoneNotification.approveAction) { backend.snapshot }

        // A stays visible on screen until its Face ID finishes:
        #expect(model.sheet.presentation == .request(id: "rA", mode: .approving, canReturnToDecide: false))

        backend.releaseApproveGate()
        await taskA.value

        #expect(backend.approvedIDs == ["rA", "rC"])
        #expect(backend.deniedIDs.map(\.0) == ["rB"])
        #expect(model.sheet.presentation == .none)
    }

    @MainActor
    @Test("Disappearing request during cancelled auth clears sheet instead of leaving a stuck spinner")
    func disappearingRequestDuringCancelledAuthClearsSheet() async {
        var snap = PhoneSnapshot(firstRun: .finished, requests: [makeWaitingRequest(id: "rA")])
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        backend.blockApproveForID = "rA"
        backend.failApproveForID = "rA"
        let model = PhoneModel(backend: backend, initial: snap)

        let taskA = Task { @MainActor in
            await model.handleNotification(id: "rA", action: PhoneNotification.approveAction) { backend.snapshot }
        }
        await backend.waitForApproveGate()

        // Request A disappears from snapshot while authenticating:
        var gone = snap
        gone.revision = 2
        gone.requests = []
        model.applySnapshot(gone)

        // Now Face ID cancels: sheet MUST dismiss cleanly (never stay open with nil request!).
        backend.releaseApproveGate()
        await taskA.value

        #expect(model.sheet.presentation == .none)
        #expect(model.sheet.item == nil)
    }

    @MainActor
    @Test("Practice Cancel followed by 30-second timer never reopens sheet, and Send Another / Try Again / Skip work")
    func practiceCancelThenTimerNeverReopensAndActionsWork() async {
        let backend = SandboxWorld()
        backend.set { $0.showPhone(step: "practice") }
        let model = PhoneModel(backend: backend, initial: backend.phoneSnapshot)

        #expect(model.sheet.presentation == .request(id: "practice", mode: .decide, canReturnToDecide: false))

        model.dismissSheet(expectedItem: .request(id: "practice"))
        try? await Task.sleep(for: .milliseconds(30))
        model.applySnapshot(backend.phoneSnapshot)

        #expect(model.sheet.presentation == .none)
        #expect(model.snapshot.firstRun == .practiceWaiting(id: "practice", arrived: true))

        await model.sendFirstRunEvent(.practiceTimedOut(pushAddress: true))
        model.applySnapshot(backend.phoneSnapshot)
        #expect(model.snapshot.firstRun == .practiceWaiting(id: "practice", arrived: true))
        #expect(model.sheet.presentation == .none)

        #expect(PhoneFirstRun.practiceWaiting(id: "p1", arrived: true).on(.sendPractice(id: "p2")) == .practiceWaiting(id: "p2", arrived: false))
        #expect(PhoneFirstRun.practice(id: "p1").on(.sendPractice(id: "p2")) == .practiceWaiting(id: "p2", arrived: false))
        #expect(PhoneFirstRun.practiceWaiting(id: "p1", arrived: true).on(.continueAfterPractice(watchToAdd: true)) == .readyOfferWatch(watchToAdd: true))
    }

    @MainActor
    @Test("Scoped dismissal cannot dismiss a newer sheet, and Settings yields cleanly to notification taps")
    func scopedDismissalAndSettingsSheet() async {
        var snap = PhoneSnapshot(firstRun: .finished, requests: [makeWaitingRequest(id: "r1"), makeWaitingRequest(id: "r2")])
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        let model = PhoneModel(backend: backend, initial: snap)

        model.openSettings()
        #expect(model.sheet.presentation == .settings)

        await model.handleNotification(id: "r1", action: "DEFAULT") { backend.snapshot }
        #expect(model.sheet.presentation == .request(id: "r1", mode: .decide, canReturnToDecide: false))

        model.dismissSheet(expectedItem: .settings)
        model.dismissSheet(expectedItem: .request(id: "r2"))
        #expect(model.sheet.presentation == .request(id: "r1", mode: .decide, canReturnToDecide: false))

        var gone = snap
        gone.revision = 2
        gone.requests = [makeWaitingRequest(id: "r2")]
        model.applySnapshot(gone)
        #expect(model.sheet.presentation == .none)
        #expect(model.sheet.item == nil)
    }

    @MainActor
    @Test("Practice Approve notification with followUpdates running has zero intermediate ghost sheet")
    func practiceApproveWithFollowUpdatesHasZeroGhostSheet() async {
        let backend = SandboxWorld()
        backend.set { $0.showPhone(step: "practice-waiting") }
        let model = PhoneModel(backend: backend, initial: backend.phoneSnapshot)
        let follow = Task { @MainActor in await model.followUpdates() }
        defer { follow.cancel() }

        await model.handleNotification(id: "practice", action: PhoneNotification.approveAction) {
            await backend.sendFirstRunEvent(.practiceTapped)
            return backend.phoneSnapshot
        }
        for _ in 0..<100 where model.snapshot.firstRun != .practiceResult(.approved) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.snapshot.firstRun == .practiceResult(.approved))
        #expect(model.sheet.presentation == .none)
        #expect(model.sheet.item == nil)
    }

    @MainActor
    @Test("Queued ordinary tap on B followed by Lock Screen Deny on C executes Deny on C even without answering B")
    func queuedTapThenBackgroundDenyNeverStrandsDeny() async {
        var snap = PhoneSnapshot(
            firstRun: .finished,
            requests: [makeWaitingRequest(id: "rA"), makeWaitingRequest(id: "rB"), makeWaitingRequest(id: "rC")]
        )
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        backend.blockApproveForID = "rA"
        let model = PhoneModel(backend: backend, initial: snap)

        let taskA = Task { @MainActor in
            await model.handleNotification(id: "rA", action: PhoneNotification.approveAction) { backend.snapshot }
        }
        await backend.waitForApproveGate()

        // Queue ordinary tap on B, then Lock Screen Deny on C while A authenticates:
        await model.handleNotification(id: "rB", action: "DEFAULT") { backend.snapshot }
        await model.handleNotification(id: "rC", action: PhoneNotification.denyAction) { backend.snapshot }

        backend.releaseApproveGate()
        await taskA.value

        // C's Lock Screen Deny MUST execute immediately (never stranded behind B's Decide sheet!),
        // and B opens cleanly in Decide mode!
        #expect(backend.approvedIDs == ["rA"])
        #expect(backend.deniedIDs.map(\.0) == ["rC"])
        #expect(model.sheet.presentation == .request(id: "rB", mode: .decide, canReturnToDecide: false))
    }

    @MainActor
    @Test("Returned snapshot containing practice or ended state during loadNotice never hijacks Approve or hides staleNotice")
    func refreshedSnapshotDuringLoadNoticePreservesIntentAndStaleNotice() async {
        var snap = PhoneSnapshot(firstRun: .practiceWaiting(id: "practice", arrived: true), requests: [makeWaitingRequest(id: "rB")])
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        let model = PhoneModel(backend: backend, initial: snap)

        // Loader returns the first snapshot containing practiceRequest: B's Approve MUST still run!
        await model.handleNotification(id: "rB", action: PhoneNotification.approveAction) {
            var next = backend.snapshot
            next.revision &+= 1
            next.firstRun = .practice(id: "practice")
            next.practiceRequest = .practiceAccessRequest()
            backend.emit(next)
            return next
        }
        #expect(backend.approvedIDs == ["rB"])

        // Tapping an already-ended request whose loader returns the ended snapshot MUST still set staleNotice!
        var endedSnap = backend.snapshot
        endedSnap.revision &+= 1
        var endedReq = makeWaitingRequest(id: "rEnded")
        endedReq.state = .approved(by: .mac, until: .now.addingTimeInterval(600))
        endedSnap.requests.append(endedReq)
        backend.emit(endedSnap)

        await model.handleNotification(id: "rEnded", action: "DEFAULT") { backend.snapshot }
        #expect(model.sheet.presentation == .none)
        #expect(model.sheet.staleNotice == PhoneCopy.staleRequestNote(endedReq.state))
    }

    @MainActor
    @Test("Interrupting Add Apple Watch with a notification cancels addWatch cleanly so Add Apple Watch can reopen")
    func addWatchInterruptedByNotificationCanReopen() async {
        var snap = PhoneSnapshot(firstRun: .finished, requests: [makeWaitingRequest(id: "r1")])
        snap.revision = 1
        snap.addWatch = .faceIDFirst
        let backend = ControlledPhoneBackend(initial: snap)
        let model = PhoneModel(backend: backend, initial: snap)
        #expect(model.sheet.presentation == .addWatch)

        // Notification arrives while Add Apple Watch is open: must replace sheet cleanly.
        await model.handleNotification(id: "r1", action: "DEFAULT") { backend.snapshot }
        #expect(model.sheet.presentation == .request(id: "r1", mode: .decide, canReturnToDecide: false))

        // Dismiss the notification sheet, then tap Add Apple Watch again: must reopen instead of no-op.
        model.dismissSheet(expectedItem: .request(id: "r1"))
        #expect(model.sheet.presentation == .none)
        await model.handleAddWatchTap(.open)
        #expect(model.sheet.presentation == .addWatch)
    }

    @MainActor
    @Test("Device removal closes lingering Settings or Add Watch sheets")
    func deviceRemovalClosesLingeringPostFirstRunSheet() {
        var snap = PhoneSnapshot(firstRun: .finished)
        snap.revision = 1
        let backend = ControlledPhoneBackend(initial: snap)
        let model = PhoneModel(backend: backend, initial: snap)
        model.openSettings()
        #expect(model.sheet.presentation == .settings)

        var removed = PhoneSnapshot(firstRun: .start)
        removed.revision = 2
        model.applySnapshot(removed)
        #expect(model.sheet.presentation == .none)
    }
}
