// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Agent Keyring on the Apple Watch. It sets itself up with nothing for the
// person to do but what Apple asks: it makes its keys, gets its push address
// and hands both to the iPhone, which adds it. Whichever app is opened first,
// or neither, the two finish setting up when they next meet.

import AgentKeyringProtocol
import AgentKeyringWatchCore
import LocalAuthentication
import OSLog
import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

let log = Logger(subsystem: "com.joshpalmer.AgentKeyring.Watch", category: "watch")

@main
struct AgentKeyringWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { WatchHome(model: WatchModel.shared) }
        WKNotificationScene(controller: RequestController.self, category: WatchWords.requestCategory)
    }
}

/// What the Watch's own screen shows: one plain line.
@MainActor @Observable
final class WatchModel {
    static let shared = WatchModel()

    enum Setup: Equatable { case setUpIPhone, approveOnIPhone, waitingForApple, ready, failed(String) }
    var setup: Setup = {
        let saved = WatchStore().read()
        return saved.lists((try? WatchKeys().keyID()) ?? "") ? .ready : saved.signedMembers != nil ? .approveOnIPhone : .setUpIPhone
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
        // Apple asks the person once, the first time the app is in front.
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await WatchLink.shared.refreshSetup()
            await WatchLink.shared.sendHandOver()
        }
    }

    /// Our own Deny and Approve sit in the layout; Apple's Deny and Explain
    /// sits under it. It is marked destructive, so a Double Tap cannot choose it.
    static let requestCategory = UNNotificationCategory(identifier: WatchWords.requestCategory, actions: [
        UNTextInputNotificationAction(identifier: WatchWords.denyAndExplain, title: "Deny and Explain", options: [.destructive],
                                      textInputButtonTitle: "Done", textInputPlaceholder: "What should it do instead?"),
    ], intentIdentifiers: [])

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchLink.shared.pushToken = deviceToken
        Task { await WatchLink.shared.refreshSetup(); await WatchLink.shared.sendHandOver() }
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == WatchWords.denyAndExplain,
              let request = try? WatchRequest.from(userInfo: response.notification.request.content.userInfo,
                                                   keys: WatchKeys(), saved: WatchStore().read()) else { completionHandler(); return }
        let words = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let done = UncheckedHandler(completionHandler)
        Task {
            do { _ = try await WatchAnswers().deny(request, words: words) }
            catch { WatchLink.shared.report(problem: "Deny and Explain did not reach the relay: \(error)") }
            done.call()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Apple Watch's words on its own screen (Paper, "First run", "On Apple Watch"
/// and "When something needs you"). The line stands alone, with no mark.
enum WatchCopy {
    static let setUpIPhone = "Set up your iPhone first"
    static let setUpIPhoneDetail = "Open Agent Keyring on your iPhone."
    static let approveOnIPhone = "Approve on your iPhone"
    static let approveOnIPhoneDetail = "A request to add this Apple Watch has appeared there."
    static let ready = "Ready"
    static let readyDetail = "Requests arrive as notifications."
    /// Not on the second board: kept from the first.
    static let waitingForApple = "Waiting for Apple"
    static let waitingForAppleDetail = "Requests can’t reach your Apple Watch yet."
    static let noPasscode = "Set a passcode in the Apple Watch app on your iPhone to approve from your wrist."
    static let notificationsOff = "Turn on notifications for Agent Keyring in the Apple Watch app on your iPhone."
}

struct WatchHome: View {
    let model: WatchModel

    var body: some View {
        VStack(spacing: 6) {
            switch model.setup {
            case .setUpIPhone: titled(WatchCopy.setUpIPhone, WatchCopy.setUpIPhoneDetail)
            case .approveOnIPhone: titled(WatchCopy.approveOnIPhone, WatchCopy.approveOnIPhoneDetail)
            case .waitingForApple: titled(WatchCopy.waitingForApple, WatchCopy.waitingForAppleDetail)
            case .ready:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.white, .green)
                titled(WatchCopy.ready, WatchCopy.readyDetail)
            case .failed(let line):
                Text(line).font(.system(size: 15)).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder private func titled(_ title: String, _ detail: String) -> some View {
        Text(title).font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
        Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
}

struct UncheckedHandler: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
