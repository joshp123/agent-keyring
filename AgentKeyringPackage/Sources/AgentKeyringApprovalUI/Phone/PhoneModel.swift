// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// What the iPhone app shows and what it can ask for. Views read the model;
// everything real (the Mac's door, push, the Secure Enclave and Face ID) sits
// behind PhoneBackend.

import Foundation
import Observation
import UserNotifications

/// A saved login as the iPhone lists it. Site and account are readable;
/// the password stays sealed.
public struct PhoneLogin: Identifiable, Hashable, Sendable {
    public enum Rule: Hashable, Sendable {
        case ask, automatic, blocked
    }

    public let id: String
    public var site: String
    public var account: String
    public var rule: Rule

    public init(id: String, site: String, account: String, rule: Rule) {
        self.id = id; self.site = site; self.account = account; self.rule = rule
    }
}

public struct PhoneDevice: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// A device that approves: this iPhone, a Watch, a MacBook.
        case approves
        /// A machine whose agents ask.
        case asks
    }

    public let id: String
    public var name: String
    /// How it approves, or what it does: "Face ID", "Always on. Passes requests…".
    public var detail: String?
    public var role: Role
    public var isThisIPhone: Bool
    /// Practice on its row: a device he answers on, other than this iPhone.
    public var canPractice: Bool
    /// Remove on its row: not this iPhone, and not a Mac's computer row (its device row removes both).
    public var canRemove: Bool

    public init(id: String, name: String, detail: String? = nil, role: Role, isThisIPhone: Bool = false,
                canPractice: Bool = false, canRemove: Bool = true) {
        self.id = id; self.name = name; self.detail = detail; self.role = role; self.isThisIPhone = isThisIPhone
        self.canPractice = canPractice; self.canRemove = canRemove
    }
}

public enum PhoneTab: String, Hashable, Sendable {
    case home, logins, devices
}

/// One sentence in Activity when something needs him, or an offer he can dismiss.
public enum PhoneNotice: Hashable, Sendable, Identifiable {
    /// Apple has not yet given this iPhone a push address.
    case stillConnecting
    /// The Mac can't be reached, so lists and practice requests wait for it; its name if known.
    case macOffline(String?)
    /// An Apple Watch is paired and has not been added.
    case addAppleWatch

    public var id: String {
        switch self {
        case .stillConnecting: "stillConnecting"
        case .macOffline: "macOffline"
        case .addAppleWatch: "addAppleWatch"
        }
    }
    public var dismissable: Bool { self == .addAppleWatch }
}

public struct PhoneFill: Hashable, Sendable {
    public var copied: Int
    public var of: Int
    public init(copied: Int, of: Int) { self.copied = copied; self.of = of }
}

/// What the iPhone can see of its Apple Watch, each a fact the Apple Watch step ticks. The iPhone cannot
/// open or install the Watch app; it can only see these.
public struct PhoneWatchFacts: Hashable, Sendable {
    /// An Apple Watch is paired with this iPhone (WatchConnectivity).
    public var paired = false
    /// Agent Keyring's Watch app is installed on it.
    public var installed = false
    /// The Watch app has run and sent this iPhone its keys.
    public var opened = false
    /// It is in the list of devices.
    public var added = false
    /// It is listed in Members, but its encrypted password copies have not yet been acknowledged by the Mac.
    public var copiesPending = false
    public var notificationsAllowed = false
    /// Apple has given it a push address.
    public var pushAddress = false
    /// It has answered a practice request.
    public var practiceAnswered = false

    public init() {}

    /// Paired and either not added or still missing its encrypted password copies:
    /// keeps the Add Apple Watch flow reachable until copying completes.
    public var toAdd: Bool { paired && (!added || copiesPending) }
}

/// What iOS lets the app see of its notification settings: the facts the notifications checklist ticks.
/// Whether a Focus such as Sleep lets requests through is not among them: no app can read it.
public struct PhoneNotificationFacts: Hashable, Sendable {
    public var allowed = false
    public var banners = false
    public var lockScreen = false
    public var timeSensitive = false
    /// Delivered in a Scheduled Summary, which would hold requests back.
    public var inScheduledSummary = false

    public init() {}

    public init(_ settings: UNNotificationSettings) {
        allowed = settings.authorizationStatus == .authorized
        banners = settings.alertSetting == .enabled
        lockScreen = settings.lockScreenSetting == .enabled
        timeSensitive = settings.timeSensitiveSetting == .enabled
        inScheduledSummary = settings.scheduledDeliverySetting == .enabled
    }
}

/// The two notification settings (Paper, "On iPhone and Apple Watch", Settings).
public struct PhoneSettings: Hashable, Sendable {
    public var timeSensitive: Bool
    public var quietHours: Bool
    /// Minutes after midnight.
    public var quietFrom: Int
    public var quietTo: Int

    public init(timeSensitive: Bool = true, quietHours: Bool = false, quietFrom: Int = 23 * 60, quietTo: Int = 7 * 60) {
        self.timeSensitive = timeSensitive; self.quietHours = quietHours; self.quietFrom = quietFrom; self.quietTo = quietTo
    }
}

public struct PhoneSnapshot: Hashable, Sendable {
    /// Monotonic revision set by the backend so delayed AsyncStream snapshots never overwrite newer state.
    public var revision: UInt64 = 0
    public var requests: [AccessRequest]
    public var logins: [PhoneLogin]
    public var devices: [PhoneDevice]
    public var firstRun: PhoneFirstRun
    /// First run's practice request, in the real request's layout, while it is open.
    public var practiceRequest: AccessRequest?
    /// The reply sent with a denied practice request, if any, to echo on the confirmation card.
    public var practiceDeniedReply: String?
    /// The Mac this iPhone joined, by name.
    public var macName: String?
    /// What this iPhone can see of its Apple Watch, for the Apple Watch step.
    public var watch = PhoneWatchFacts()
    public var notices: [PhoneNotice] = []
    public var settings = PhoneSettings()
    public var notificationFacts = PhoneNotificationFacts()
    /// Adding Apple Watch, while its flow is open.
    public var addWatch: PhoneAddWatch?
    /// While this iPhone's copies of the passwords arrive after joining: how many are here, of how many.
    public var filling: PhoneFill?
    /// Requests whose answer is not delivered yet: the asking computer's door cannot be reached, and it is retried.
    public var undelivered: Set<String> = []
    /// In the signed list of devices.
    public var joined = false

    public init(firstRun: PhoneFirstRun, requests: [AccessRequest] = [], logins: [PhoneLogin] = [], devices: [PhoneDevice] = [],
                practiceRequest: AccessRequest? = nil) {
        self.firstRun = firstRun; self.requests = requests; self.logins = logins; self.devices = devices
        self.practiceRequest = practiceRequest
    }
}

/// Stop could not reach the asking computer, so it waits with the Mac until that computer next asks.
public struct PhoneStopWaitsWithMac: Error { public init() {} }

@MainActor
public protocol PhoneBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func updates() -> AsyncStream<PhoneSnapshot>
    /// Face ID, then the answer goes to the machine that asked. `reusingUnlock`:
    /// a Face ID unlock of the phone in the last few seconds counts, so an
    /// Approve pressed on the Lock Screen needs one look, not two.
    func approve(_ requestID: String, reusingUnlock: Bool) async throws
    func deny(_ requestID: String, reply: String?) async throws
    func stop(_ requestID: String) async throws
    /// Changing a rule is signed by this iPhone after Face ID.
    func setRule(_ rule: PhoneLogin.Rule, forLogin loginID: String) async throws
    /// Removing a device is signed by this iPhone after Face ID.
    func remove(device deviceID: String) async throws
    /// Uses the Mac's join card from an `agentkeyring://join` link, for the simulator, which has no iCloud Keychain.
    func join(invitation: String) async throws
    /// A step of first run: a tap, or what iOS answered.
    func firstRun(_ event: PhoneFirstRun.Event) async
    /// What iOS now allows, read each time the app comes to the front and after its question.
    func notificationFacts(_ facts: PhoneNotificationFacts) async
    /// A practice request to this iPhone (nil) or to another device he answers on. For this iPhone, returns
    /// the one already waiting, to be shown again, instead of making a second.
    func sendPractice(to deviceID: String?) async -> String?
    func dismiss(_ notice: PhoneNotice) async
    func setSettings(_ settings: PhoneSettings) async
    /// A tap in the Apple Watch flow.
    func addWatch(_ tap: PhoneAddWatchTap) async
}

@MainActor
@Observable
public final class PhoneModel {
    public private(set) var snapshot: PhoneSnapshot
    public var tab = PhoneTab.home
    /// Single explicit state machine for every modal sheet, notification open, and per-request reply draft.
    public private(set) var sheet = PhoneSheetState()
    public private(set) var answering: AnswerChoice?
    /// The specific request ID currently authenticating or sending an answer.
    public private(set) var answeringID: String?
    public private(set) var failure: String?
    /// In-flight guards for non-request actions so double taps never overlap Face ID or 30s retries.
    public private(set) var isAskingNotifications = false
    public private(set) var isAuthorizingWatch = false
    public private(set) var stoppingIDs: Set<String> = []
    public private(set) var isChangingRuleOrDevice = false

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
        for await next in backend.updates() {
            applySnapshot(next)
        }
    }

    /// Synchronizes `sheet` deterministically whenever the backend emits a new snapshot.
    /// Rejects stale snapshots whose revision is strictly older than the current snapshot.
    public func applySnapshot(_ next: PhoneSnapshot) {
        if next.revision > 0, next.revision < snapshot.revision { return }
        let previous = snapshot
        snapshot = next

        if let openID = sheet.requestID, openID != loadingNotificationID, openID != answeringID {
            let current = request(id: openID)
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

    public func request(id: String) -> AccessRequest? {
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
        if replacingAddWatch { Task { await backend.addWatch(.cancel) } }
    }

    public func explain(_ id: String) {
        guard answeringID == nil else { return }
        let replacingAddWatch = sheet.presentation == .addWatch
        if snapshot.firstRun == .finished { tab = .home }
        notificationToken &+= 1
        loadingNotificationID = nil
        sheet.apply(.openExplain(id: id))
        if replacingAddWatch { Task { await backend.addWatch(.cancel) } }
    }

    public func openSettings() {
        guard answeringID == nil, loadingNotificationID == nil else { return }
        let replacingAddWatch = sheet.presentation == .addWatch
        notificationToken &+= 1
        sheet.apply(.openSettings)
        if replacingAddWatch { Task { await backend.addWatch(.cancel) } }
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
    public func dismissSheet(expectedItem: PhoneSheetState.SheetItem? = nil) {
        if let expectedItem, sheet.item != expectedItem { return }
        let openRequestID = sheet.requestID
        let wasAddWatch = (sheet.presentation == .addWatch)
        sheet.apply(.dismiss(expectedItem: expectedItem))
        if let openRequestID, openRequestID == snapshot.firstRun.practiceID || openRequestID == snapshot.practiceRequest?.id {
            Task { await firstRun(.practiceDismissed) }
        } else if wasAddWatch {
            Task { await addWatch(.cancel) }
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
            guard let current = request(id: id), current.state.isWaitingForYou else { return }
            await answer(id, choice: .deny) { try await backend.deny(id, reply: nil) }
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
        if replacingAddWatch { Task { await backend.addWatch(.cancel) } }

        let refreshed = await loadNotice()
        // Keep `loadingNotificationID == id` during `applySnapshot` so a returned snapshot containing
        // practice or an ended state cannot hijack the sheet or skip setting `staleNotice`.
        if let refreshed { applySnapshot(refreshed) }
        if loadingNotificationID == id { loadingNotificationID = nil }

        // A newer explicit tap or sheet change took over while `loadNotice` was suspended: never act behind its back.
        guard token == notificationToken, sheet.requestID == id else { return }

        guard let current = request(id: id) else {
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
            await approve(id, reusingUnlock: true)
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

    public func approve(_ id: String, reusingUnlock: Bool = false) async {
        guard answeringID == nil else { return }
        sheet.apply(.approveStarted(id: id))
        await answer(id, choice: .approve) { try await backend.approve(id, reusingUnlock: reusingUnlock) }
    }

    public func deny(_ id: String, withDraft: Bool = true) async {
        guard answeringID == nil else { return }
        let reply = withDraft ? sheet.draft(for: id).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        await answer(id, choice: .deny) { try await backend.deny(id, reply: reply.isEmpty ? nil : reply) }
    }

    public func stop(_ id: String) async {
        guard !stoppingIDs.contains(id) else { return }
        stoppingIDs.insert(id)
        defer { stoppingIDs.remove(id) }
        do { try await backend.stop(id) } catch is PhoneStopWaitsWithMac {
            failure = PhoneCopy.stopLeftWithMac
        } catch {
            var until: Date?
            if case let .approved(_, end)? = request(id: id)?.state { until = end }
            failure = PhoneCopy.stopFailed(until: until)
        }
    }

    public func setRule(_ rule: PhoneLogin.Rule, forLogin id: String) async {
        guard !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do { try await backend.setRule(rule, forLogin: id) }
        catch is CancellationError {}
        catch { failure = PhoneCopy.changeFailed }
    }

    public func remove(device id: String) async {
        guard !isChangingRuleOrDevice else { return }
        isChangingRuleOrDevice = true
        defer { isChangingRuleOrDevice = false }
        do { try await backend.remove(device: id) }
        catch is CancellationError {}
        catch { failure = PhoneCopy.changeFailed }
    }

    public func join(invitation: String) async {
        try? await backend.join(invitation: invitation)
    }

    /// What iOS now allows, read again each time the app comes to the front: he may
    /// have turned notifications on in Settings, and first run then carries on by itself.
    public func recheckNotifications() async {
        guard !isAskingNotifications else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await backend.notificationFacts(PhoneNotificationFacts(settings))
        guard settings.authorizationStatus != .notDetermined else { return }
        await backend.firstRun(.notificationsAnswered(allowed: settings.authorizationStatus == .authorized))
    }

    /// iOS's own question, raised by Continue on the screen that says why.
    public func askAboutNotifications() async {
        guard snapshot.firstRun == .notifications, !isAskingNotifications else { return }
        isAskingNotifications = true
        defer { isAskingNotifications = false }
        await backend.firstRun(.continueTapped)
        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await backend.notificationFacts(PhoneNotificationFacts(await UNUserNotificationCenter.current().notificationSettings()))
        await backend.firstRun(.notificationsAnswered(allowed: allowed))
    }

    public func firstRun(_ event: PhoneFirstRun.Event) async {
        await backend.firstRun(event)
        if snapshot.firstRun == .finished { tab = .home }
    }

    public func sendPractice(to deviceID: String? = nil) async {
        if let waiting = await backend.sendPractice(to: deviceID) { openDecide(waiting) }
    }
    public func dismiss(_ notice: PhoneNotice) async { await backend.dismiss(notice) }
    public func setSettings(_ settings: PhoneSettings) async { await backend.setSettings(settings) }

    public func addWatch(_ tap: PhoneAddWatchTap) async {
        if tap == .continueWithFaceID {
            guard !isAuthorizingWatch else { return }
            isAuthorizingWatch = true
            defer { isAuthorizingWatch = false }
            await backend.addWatch(tap)
            return
        }
        await backend.addWatch(tap)
        if tap == .open, snapshot.firstRun == .finished, snapshot.addWatch != nil,
           sheet.presentation == .none, answeringID == nil, loadingNotificationID == nil {
            sheet.apply(.openAddWatch)
        }
    }

    public func dismissFailure() { failure = nil }

    private func answer(_ id: String, choice: AnswerChoice, send: () async throws -> Void) async {
        guard answering == nil, answeringID == nil else { return }
        answering = choice
        answeringID = id
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
        answering = nil
        answeringID = nil
        if !ended, let openID = sheet.requestID {
            let current = request(id: openID)
            let stillPresentable = current.map { $0.state.isWaitingForYou || $0.state.isSending } ?? false
            if !stillPresentable {
                sheet.apply(.requestEnded(id: openID))
            }
        }
        await drainQueuedNotifications()
    }
}

extension AccessRequestState {
    var isSending: Bool {
        if case .sendingAnswer = self { return true }
        return false
    }
}
