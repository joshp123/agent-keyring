// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Agent Keyring on the Apple Watch. It sets itself up with nothing for the
// person to do but what Apple asks: it makes its keys, gets its push address
// and hands both to the iPhone, which adds it. Whichever app is opened first,
// or neither, the two finish setting up when they next meet.

import AgentKeyringProtocol
import AgentKeyringWatchCore
import AgentKeyringWatchUI
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

    init() {
        // A new install: removing the app cleared its own settings but not its keychain. The keys stay.
        if !UserDefaults.standard.bool(forKey: "installed") {
            WatchStore().delete()
            UserDefaults.standard.set(true, forKey: "installed")
        }
    }

    var body: some Scene {
        WindowGroup { WatchHome(model: WatchModel.shared) }
        WKNotificationScene(controller: RequestController.self, category: WatchWords.requestCategory)
    }
}

/// What the Watch's own screen shows: where setup stands, or what is in use.
@MainActor @Observable
final class WatchModel {
    static let shared = WatchModel()

    var inUse: [WatchInUse] = {
        #if DEBUG
        // -SampleInUse YES: one approval in use, for looking at "In use".
        if UserDefaults.standard.bool(forKey: "SampleInUse") {
            return [WatchInUse(id: "u1", site: "example.com", who: "Codex on Linux server", until: .now.addingTimeInterval(1500))]
        }
        #endif
        return WatchStore().readInUse()
    }()
    var setup: WatchSetup = {
        #if DEBUG
        // For comparing screens with Paper in the simulator: -SampleSetup notifications.
        let samples: [String: WatchSetup] = ["no-passcode": .noPasscode, "set-up-iphone": .setUpIPhone, "start-on-iphone": .startOnIPhone,
                                             "ready-to-add": .readyToAdd, "preparing": .preparing,
                                             "notifications": .notifications, "notifications-off": .notificationsOff,
                                             "setting-up": .settingUpNotifications, "added": .addedOfferPractice,
                                             "practice-waiting": .practiceWaiting, "ready": .ready]
        if let name = UserDefaults.standard.string(forKey: "SampleSetup"), let sample = samples[name] { return sample }
        #endif
        let saved = WatchStore().read()
        var error: NSError?
        let passcode = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        let listed = saved.lists((try? WatchKeys().keyID()) ?? "")
        let addOffered = saved.addUntil.map { $0 > .now } ?? false
        return WatchSetup(passcode: passcode,
                          phoneJoined: saved.signedMembers != nil,
                          listed: listed,
                          addOffered: addOffered,
                          addTapped: saved.isAddTappedForCurrentOffer,
                          copiesPending: saved.copiesPending == true,
                          copyingToWatch: saved.copyingToWatch == true,
                          notifications: .allowed,
                          pushAddress: WatchLink.shared.pushToken != nil || saved.practiceOfferDone == true,
                          practiceAsked: saved.practiceAnswered == true ? nil : saved.practiceAsked,
                          practiceOfferDone: saved.practiceOfferDone == true)
    }()
}

final class WatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([WatchDelegate.requestCategory])
        WatchLink.shared.activate()
        WKApplication.shared().registerForRemoteNotifications()
        #if DEBUG
        // For looking at the request card in the simulator: -AskNotifications YES.
        if UserDefaults.standard.bool(forKey: "AskNotifications") {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
        #endif
    }

    func applicationDidBecomeActive() {
        Task {
            await WatchLink.shared.refreshSetup()
            await WatchLink.shared.sendHandOver()
        }
    }

    /// No notification actions of Apple's: Approve, Deny and Deny and Explain are our own three buttons in the
    /// request's card, one kind, and with no action of Apple's there is nothing for a Double Tap to choose.
    static let requestCategory = UNNotificationCategory(identifier: WatchWords.requestCategory, actions: [], intentIdentifiers: [])

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchLink.shared.pushToken = deviceToken
        Task { await WatchLink.shared.refreshSetup(); await WatchLink.shared.sendHandOver() }
    }

    /// A silent push: a request was answered or ended. Its notification goes, and "In use" follows its outcome.
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        guard (userInfo["aps"] as? [String: Any])?["alert"] == nil, let id = userInfo["id"] as? String else { return .noData }
        watchLog.note("notification", "removed", ["request": id, "by": "silent push"])
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let same = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == id }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: same)
        let store = WatchStore()
        if let request = try? WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: store.read()) {
            store.noteOutcome(request)
            await WatchLink.shared.refreshSetup()
        }
        return .newData
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

    /// Sends the answer from the request's card. The reply is the request's Lease: if another device's
    /// answer ended it first, or it timed out/cancelled before our reply arrived, that is the outcome.
    static func answer(_ request: WatchRequest, approve: Bool, words: String) async -> WatchAnswerResult {
        watchLog.note("answer", "started", ["request": request.id, "choice": approve ? "approve" : words.isEmpty ? "deny" : "deny-with-words"])
        let saved = WatchStore().read()
        let mine = (try? WatchKeys().keyID()).flatMap { id in saved.signedMembers?.devices.first { $0.keyID == id }?.label }
        do {
            let lease: Agentkeyring_V2_Lease
            if approve {
                lease = try await WatchAnswers().approve(request)
            } else {
                lease = try await WatchAnswers().deny(request, words: words)
            }
            await removeDeliveredNotification(id: request.id)
            let answeredByOther = mine != nil && !lease.answeredBy.isEmpty && lease.answeredBy != mine
            let expectedState: Agentkeyring_V2_LeaseState = approve ? .approved : .denied
            let alreadySettled = answeredByOther || lease.state != expectedState
            if !request.isPractice {
                let store = WatchStore()
                if lease.state == .approved, lease.notAfterUnixSeconds > 0 {
                    store.addInUse(WatchInUse(id: request.id, site: request.site, who: request.who,
                                              until: Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds))))
                } else {
                    store.removeInUse(request.id)
                }
            }
            if alreadySettled {
                watchLog.note("answer", "already answered", ["request": request.id, "state": "\(lease.state)", "by": lease.answeredBy])
                await WatchLink.shared.refreshSetup()
                return .alreadyAnswered
            }
            watchLog.note("answer", "sent", ["request": request.id])
            if request.isPractice, WatchStore().read().practiceAnswered != true {
                WatchStore().update {
                    $0.practiceAnswered = true
                    $0.practiceOfferDone = true
                }
                await WatchLink.shared.sendHandOver()
            }
            await WatchLink.shared.refreshSetup()
            return .sent
        } catch {
            WatchLink.shared.report(problem: "\(approve ? "Approve" : "Deny") was not delivered: \(error)")
            return .failed
        }
    }

    private static func removeDeliveredNotification(id: String) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let same = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == id }.map(\.request.identifier)
        if !same.isEmpty { center.removeDeliveredNotifications(withIdentifiers: same) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

struct UncheckedHandler: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
