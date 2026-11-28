// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Agent Keyring on the Apple Watch. It sets itself up with nothing for the
// person to do but what Apple asks: it makes its keys, gets its push address
// and hands both to the iPhone, which adds it. Whichever app is opened first,
// or neither, the two finish setting up when they next meet.

import AgentKeyringDesign
import AgentKeyringProtocol
import AgentKeyringSealing
import AgentKeyringWatchUI
import OSLog
import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

let log = Logger(subsystem: "com.joshpalmer.AgentKeyring.Watch", category: "watch")

@main
struct AgentKeyringWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        KeyringFont.register()
        // Before any request is checked: a relay set at launch, else the one the iPhone last sent.
        WatchRelayConfiguration.launchSetting = UserDefaults.standard.string(forKey: "AgentKeyringRelayURL")
        WatchRelayConfiguration.applyRelayOverride(WatchKeychainStateStore().readWatchState())
        // A new install: removing the app cleared its own settings but not its keychain. The keys stay.
        if !UserDefaults.standard.bool(forKey: "installed") {
            WatchKeychainStateStore().deleteWatchState()
            UserDefaults.standard.set(true, forKey: "installed")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchHome(model: WatchModel.shared)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        WatchLink.shared.onForeground()
                        Task { await WatchModel.shared.pickUpDeliveredRequestNotification() }
                    }
                }
        }
        WKNotificationScene(controller: RequestController.self, category: WatchRequestDisplayCopy.requestCategory)
    }
}

/// What the Watch's own screen shows: where setup stands, or what is in use.
@MainActor @Observable
final class WatchModel {
    static let shared = WatchModel()

    var foregroundRequest: RequestModel?
    private(set) var foregroundRequestID: String?
    private var handledForegroundRequestIDs: Set<String> = []
    private var queuedForegroundRequests: [(id: String, userInfo: [AnyHashable: Any])] = []

    /// Presents a delivered notification's request card directly when the Watch app is already open
    /// in the foreground (where watchOS files incoming notifications quietly into Notification Center
    /// instead of showing the full-screen notification scene). Never replaces an active request card
    /// under the user's finger: new arrivals queue cleanly until the current card dismisses.
    func presentForegroundRequest(_ userInfo: [AnyHashable: Any], id: String) {
        guard !id.isEmpty, foregroundRequestID != id, !handledForegroundRequestIDs.contains(id) else { return }
        if foregroundRequest != nil {
            if !queuedForegroundRequests.contains(where: { $0.id == id }) {
                queuedForegroundRequests.append((id: id, userInfo: userInfo))
            }
            return
        }
        showForegroundRequest(userInfo, id: id)
    }

    private func showForegroundRequest(_ userInfo: [AnyHashable: Any], id: String) {
        let requestModel = RequestModel(backend: LiveWatchRequestBackend())
        requestModel.dismiss = { [weak self] in
            self?.dismissForegroundRequest(id: id)
        }
        requestModel.show(userInfo)
        foregroundRequestID = id
        foregroundRequest = requestModel
        WKInterfaceDevice.current().play(.notification)
    }

    func markRequestHandled(_ id: String) {
        guard !id.isEmpty else { return }
        handledForegroundRequestIDs.insert(id)
        queuedForegroundRequests.removeAll { $0.id == id }
    }

    func dismissForegroundRequest(id: String? = nil) {
        if let id {
            queuedForegroundRequests.removeAll { $0.id == id }
            if foregroundRequestID != id { return }
        }
        foregroundRequest?.close()
        foregroundRequest = nil
        foregroundRequestID = nil
        if let next = queuedForegroundRequests.first {
            queuedForegroundRequests.removeFirst()
            showForegroundRequest(next.userInfo, id: next.id)
        }
    }

    /// Picks up a real APNs request notification that watchOS delivered straight to Notification Center
    /// without invoking `willPresent` (for example while the paired iPhone screen is unlocked), and sweeps
    /// any expired or already-ended notifications from Notification Center.
    func pickUpDeliveredRequestNotification() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let store = WatchKeychainStateStore()
        let saved = store.readWatchState()
        let keys = WatchKeys()
        var staleIdentifiers: [String] = []
        var candidate: (notification: UNNotification, id: String)?

        for notification in delivered {
            let content = notification.request.content
            let id = content.threadIdentifier.isEmpty ? notification.request.identifier : content.threadIdentifier
            let aps = content.userInfo["aps"] as? [AnyHashable: Any]
            let isPassive = content.interruptionLevel == .passive || (aps?["interruption-level"] as? String) == "passive"
            if let opened = try? WatchRequest.from(userInfo: content.userInfo, keys: keys, saved: saved) {
                if case .ended = opened.state {
                    store.noteOutcome(opened)
                    markRequestHandled(id)
                    staleIdentifiers.append(notification.request.identifier)
                    staleIdentifiers.append(id)
                    continue
                }
                if opened.answerBy <= .now {
                    markRequestHandled(id)
                    staleIdentifiers.append(notification.request.identifier)
                    staleIdentifiers.append(id)
                    continue
                }
            } else if isPassive {
                markRequestHandled(id)
                staleIdentifiers.append(notification.request.identifier)
                staleIdentifiers.append(id)
                continue
            }
            if candidate == nil,
               content.categoryIdentifier == WatchRequestDisplayCopy.requestCategory,
               !handledForegroundRequestIDs.contains(id) {
                candidate = (notification, id)
            }
        }
        if !staleIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: Array(Set(staleIdentifiers)))
            Task { await WatchLink.shared.refreshSetup() }
        }
        guard foregroundRequest == nil, let match = candidate else { return }
        KeyringDiagnosticLog.watch.noteDeviceEvent("notification", "picked up delivered", ["request": match.id])
        presentForegroundRequest(match.notification.request.content.userInfo, id: match.id)
    }

    var inUse: [WatchInUse] = {
        return WatchKeychainStateStore().readInUse()
    }()
    var setup: WatchOnboardingStep = {
        return WatchLink.makeSetup(
            saved: WatchKeychainStateStore().readWatchState(),
            notifications: .allowed,
            hasPushToken: WatchLink.shared.pushToken != nil
        )
    }()
}

final class WatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([WatchDelegate.requestCategory])
        WatchLink.shared.activate()
        WKApplication.shared().registerForRemoteNotifications()
    }

    func applicationDidBecomeActive() {
        WatchLink.shared.onForeground()
    }

    /// No notification actions of Apple's: Approve, Deny and Deny and Explain are our own three buttons in the
    /// request's card, one kind, and with no action of Apple's there is nothing for a Double Tap to choose.
    static let requestCategory = UNNotificationCategory(identifier: WatchRequestDisplayCopy.requestCategory, actions: [], intentIdentifiers: [])

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchLink.shared.pushToken = deviceToken
        Task { await WatchLink.shared.refreshSetup(); await WatchLink.shared.sendHandOver(force: true) }
    }

    /// An outcome push (silent or passive collapse alert): a request was answered or ended.
    /// Its notification goes, and "In use" follows its outcome.
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let isSilent = aps?["alert"] == nil
        let isPassive = (aps?["interruption-level"] as? String) == "passive"
        guard (isSilent || isPassive), let id = userInfo["id"] as? String, !id.isEmpty else { return .noData }
        await Self.handleOutcomeNotification(id: id, userInfo: userInfo, by: isSilent ? "silent push" : "passive alert")
        return .newData
    }

    static func handleOutcomeNotification(id: String, userInfo: [AnyHashable: Any], by source: String) async {
        KeyringDiagnosticLog.watch.noteDeviceEvent("notification", "removed", ["request": id, "by": source])
        await removeDeliveredNotification(id: id)
        let store = WatchKeychainStateStore()
        if let request = try? WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: store.readWatchState()) {
            store.noteOutcome(request)
            if request.isPractice, store.readWatchState().practiceAnswered != true {
                store.update {
                    $0.practiceAnswered = true
                    $0.practiceOfferDone = true
                }
                Task { await WatchLink.shared.sendHandOver(force: true) }
            }
            await WatchLink.shared.refreshSetup()
        }
        await MainActor.run {
            WatchModel.shared.markRequestHandled(id)
            WatchModel.shared.dismissForegroundRequest(id: id)
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        log.error("No push address: \(error.localizedDescription, privacy: .public)")
        WatchLink.shared.lastProblem = "Apple gave no push address: \(error.localizedDescription)"
        Task { await WatchLink.shared.sendHandOver() }
    }

    /// The iPhone's hand-over can wake the Watch app in the background, even
    /// before the person has opened it.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let task = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchLink.shared.activate()
                WatchLink.shared.whenIdle { task.setTaskCompletedWithSnapshot(false) }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    static func removeDeliveredNotification(id: String) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let same = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == id }.map(\.request.identifier)
        if !same.isEmpty { center.removeDeliveredNotifications(withIdentifiers: same) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let id = content.threadIdentifier.isEmpty ? notification.request.identifier : content.threadIdentifier
        let aps = content.userInfo["aps"] as? [AnyHashable: Any]
        let isPassiveOutcome = content.interruptionLevel == .passive
            || (aps?["interruption-level"] as? String) == "passive"
        if isPassiveOutcome {
            let info = WatchUserInfo(content.userInfo)
            completionHandler([])
            Task {
                await Self.handleOutcomeNotification(id: id, userInfo: info.value, by: "passive alert")
            }
            return
        }
        if content.categoryIdentifier == WatchRequestDisplayCopy.requestCategory || content.userInfo["akr"] != nil {
            let info = WatchUserInfo(content.userInfo)
            KeyringDiagnosticLog.watch.noteDeviceEvent("notification", "willPresent", ["request": id])
            completionHandler([])
            Task { @MainActor in
                WatchModel.shared.presentForegroundRequest(info.value, id: id)
            }
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let id = content.threadIdentifier.isEmpty ? response.notification.request.identifier : content.threadIdentifier
        let info = WatchUserInfo(content.userInfo)
        if content.categoryIdentifier == WatchRequestDisplayCopy.requestCategory || content.userInfo["akr"] != nil {
            Task { @MainActor in
                WatchModel.shared.presentForegroundRequest(info.value, id: id)
            }
        }
        completionHandler()
    }
}

@MainActor
final class LiveWatchRequestBackend: WatchRequestBackend {
    func openRequest(_ userInfo: [AnyHashable: Any]) throws -> WatchRequest {
        try WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: WatchKeychainStateStore().readWatchState())
    }

    func askForMembers() async -> Bool {
        await WatchLink.shared.askForMembers()
    }

    func reportProblem(_ message: String) {
        WatchLink.shared.report(problem: message)
    }

    func answer(_ request: WatchRequest, approve: Bool, words: String) async -> WatchAnswerResult {
        if request.answerBy <= .now {
            noteOutcome(request)
            KeyringDiagnosticLog.watch.noteDeviceEvent("answer", "expired", ["request": request.id])
            return .alreadyAnswered
        }
        KeyringDiagnosticLog.watch.noteDeviceEvent("answer", "started", ["request": request.id, "choice": approve ? "approve" : words.isEmpty ? "deny" : "deny-with-words"])
        do {
            if approve {
                _ = try await WatchApprovalAnswerSender().sendApproval(request)
            } else {
                _ = try await WatchApprovalAnswerSender().sendDenial(request, words: words)
            }
            noteOutcome(request)
            KeyringDiagnosticLog.watch.noteDeviceEvent("answer", "sent to the box", ["request": request.id])
            finishAnswer(isPractice: request.isPractice)
            return .submitted
        } catch WatchKeyringError.alreadyAnswered {
            noteOutcome(request)
            KeyringDiagnosticLog.watch.noteDeviceEvent("answer", "already answered", ["request": request.id])
            return .alreadyAnswered
        } catch {
            reportProblem("\(approve ? "Approve" : "Deny") was not delivered: \(error)")
            return .failed
        }
    }

    private func noteOutcome(_ request: WatchRequest) {
        Task { await WatchDelegate.removeDeliveredNotification(id: request.id) }
        WatchLink.shared.sendDismissRequest(request.id)
        WatchModel.shared.markRequestHandled(request.id)
        if case .ended = request.state {
            WatchKeychainStateStore().noteOutcome(request)
        }
    }

    private func finishAnswer(isPractice: Bool) {
        Task {
            if isPractice, WatchKeychainStateStore().readWatchState().practiceAnswered != true {
                WatchKeychainStateStore().update {
                    $0.practiceAnswered = true
                    $0.practiceOfferDone = true
                }
                await WatchLink.shared.sendHandOver(force: true)
            }
            await WatchLink.shared.refreshSetup()
        }
    }
}

struct UncheckedHandler: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
